# Doe

<p align="center">
  <img src="assets/doe-logo.svg" alt="Doe logo" width="96" />
</p>

<p align="center">
  <a href="https://github.com/doerun/doe/actions/workflows/webgpu-package-surface.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/doerun/doe/webgpu-package-surface.yml?branch=main&amp;label=build" /></a>
  <a href="https://www.npmjs.com/package/doe-gpu"><img alt="npm version" src="https://img.shields.io/npm/v/doe-gpu.svg?label=version" /></a>
  <a href="https://github.com/doerun/doe/blob/main/LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg" /></a>
  <a href="https://github.com/doerun/doe/pulls"><img alt="PRs welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" /></a>
</p>

**A contract-driven WebGPU runtime and compiler designed to replace the implementation _beneath_ WebGPU**

Doe is an independent implementation of the WebGPU runtime and compiler stack. Its goal is not to invent another graphics API or ask developers to rewrite applications. Instead, Doe targets the implementation seam currently occupied by Dawn (runtime) and Tint (WGSL compiler), while preserving the existing public WebGPU contract.

Applications continue to use `navigator.gpu`, WGSL, and the WebGPU specification. The browser, renderer, sandbox, and application-facing API remain unchanged. Doe replaces only the implementation beneath that boundary.

The project is intentionally evidence-driven. Every technical claim is tied to deterministic workloads, reproducible artifacts, and explicit promotion gates rather than repository size, benchmark screenshots, or implementation volume.

---

# Vision

Modern GPU software stacks increasingly need to target heterogeneous hardware while preserving one coherent program identity.

Today a single workload may exist simultaneously as:

* WGSL source
* intermediate representations
* backend-specific shader binaries
* runtime command graphs
* execution traces
* benchmark receipts
* validation artifacts
* deployment metadata

These representations often become disconnected, making optimization, debugging, portability, benchmarking, and verification progressively harder.

Doe's long-term vision is to preserve a single identity chain from source program to execution result regardless of backend.

Rather than treating every backend as an unrelated compiler target, Doe treats lowering as successive realizations of one program.

---

# Goals

Doe has two product goals and one development-system goal.

## 1. Own the WebGPU implementation seam

Replace the implementation beneath the WebGPU API while preserving everything above it.

The target boundary is:

* WebGPU API compatibility
* Chromium integration
* browser process topology
* renderer behavior
* sandbox model
* governed fallback behavior

Doe does **not** attempt to replace Blink, HTML, CSS, JavaScript, browser security, or the surrounding browser architecture.

Today this is a long-term target rather than a completed capability.

---

## 2. Preserve program identity across heterogeneous backends

Doe aims to preserve one program while producing target-specific realizations for different execution environments.

Those targets include conventional GPU backends such as:

* Metal
* Vulkan
* Direct3D 12

and longer-term spatial-compute paths, including the Doppler Program Bundle → HostPlan → Cerebras execution lane.

The objective is not "compile once everywhere."

The objective is:

> preserve one program's identity while allowing backend-specific realization without losing provenance.

Source, lowering, runtime artifacts, execution receipts, traces, and results remain explicitly linked.

---

## 3. Demonstrate contract-driven development

Doe is also an experiment in building large software systems with AI.

Humans define intent.

Humans approve contracts.

AI agents implement bounded obligations.

Deterministic gates evaluate correctness.

Evidence determines technical eligibility.

Humans retain promotion authority.

Lean proofs are used where explicitly required, but they are one component of a larger gate system that also includes schemas, correctness tests, replay, comparability, benchmark evidence, trace validation, and claim governance.

---

# Why Doe Exists

Doe is not primarily a "Zig project."

It is a systems architecture project.

Its central hypothesis is that one focused runtime/compiler/evidence system can:

* preserve source-to-result identity
* specialize stable work earlier
* remove unnecessary runtime decisions
* make unsupported behavior explicit
* produce reproducible execution evidence
* make performance claims independently auditable

Zig enables this architecture through explicit memory management, predictable compilation, and small dependency surfaces, but Zig itself is not the product thesis.

---

# Strategy

Doe intentionally attacks a narrow engineering seam.

Rather than replacing an entire browser, operating system, or graphics ecosystem, it focuses on the implementation beneath WebGPU.

Development proceeds one product surface at a time.

Current major surfaces include:

* native runtime
* JavaScript package
* compiler
* backend emitters
* browser integration
* benchmarking
* proof pipeline
* workload system

Each surface has independent evidence requirements before stronger public claims are allowed.

Unsupported behavior is explicit.

Silent fallback is considered a failure.

Claims are promoted only after passing the gates defined for that surface.

---

# Evidence First

Every significant claim in Doe should be answerable by executable evidence.

Examples include:

* workload receipts
* trace artifacts
* replay validation
* benchmark reports
* proof artifacts
* browser diagnostics
* backend validation
* structural equivalence reports

Documentation describes the architecture.

Artifacts establish what has actually been demonstrated.

---

# Current Scope

Today Doe provides substantial evidence around:

* native runtime execution
* package surfaces
* workload contracts
* benchmark infrastructure
* proof infrastructure
* backend lowering
* reproducible claim governance

Browser replacement remains an explicit future product lane.

The current browser package delegates to the platform WebGPU implementation and should not be confused with the future Chromium runtime integration.

---

# Roadmap

The current roadmap focuses on five areas.

### Complete implementation parity

Continue closing WGSL frontend and backend gaps while maintaining exact comparison against incumbent implementations.

### Expand promoted surfaces

Advance native, package, backend, drop-in, and browser surfaces independently through evidence-driven promotion.

### Browser replacement

Produce a fully evidenced Chromium integration running Doe beneath `navigator.gpu` with governed fallback disabled for measured workloads.

### Spatial compute

Complete the Program Bundle → HostPlan → execution pipeline through simulation and ultimately hardware-backed evidence for Cerebras-class systems.

### Development system

Continue refining contract-driven engineering, where executable specifications, deterministic gates, reproducible artifacts, and bounded AI implementation scale together.

---

# Project Philosophy

Doe follows a simple rule:

**Choose a narrow seam. Preserve the contract above it. Make every claim executable.**

Large systems become understandable when every promotion is backed by evidence rather than confidence.

That philosophy applies equally to runtime behavior, compiler correctness, benchmarking, proof obligations, browser integration, and AI-assisted development.
