# Software Requirements Specification — Formally Verified CUDA → HIP Transpiler (v1 PoC)

**Version:** 1.0 (build-mode reference)
**Date:** 2026-09-20
**Repo:** `/home/titan/projects/cuda-rocm`
**Status:** Approved scope for v1 PoC. This document is the single source of truth; code must match it.

---

## 1. Purpose

Build a **formally verified source-to-source transpiler** from a frozen CUDA subset to portable HIP/ROCm, with a machine-checked proof of semantic preservation for the core mapping.

- **v1 delivers:** working prototype **plus** Rocq proof of the core, in parallel.
- **v1 explicitly defers:** performance parity/autotuning and inline-PTX translation (reserved hooks only, no behavior).

## 2. Background and related work (why this project is novel)

No formally verified CUDA→ROCm transpiler exists. Surrounding evidence:

- **Unverified translators (functional neighbors, no proof):** `HIPIFY` (`hipify-clang` AST + `hipify-perl` regex, plus `hipify_torch`) is the official AMD tool but documented as non-seamless (manual review/debug/perf rework required). A 600k-test Varity study found ~1% FP64 and ~9% FP32 numeric divergence NVIDIA vs AMD including HIPIFY-converted code. `ZLUDA` (PTX-JIT, alpha) and `SCALE` (closed-source AOT, only one handling inline PTX) validate the LLVM-IR-level approach without providing reusable proofs.
- **Proof technology (proofs, wrong domain):** `CompCert` (Rocq, verified C→ASM) gives the architecture pattern (unverified parser + verified core + extraction). `Vellvm` (Rocq LLVM-IR semantics) and `Alive2` (bounded SMT translation validation for LLVM IR) are the stage-2 validation stack. `GPUVerify`/`PUG` (Boogie/Z3, SDV semantics) prove race/divergence-freedom but do not transpile. The ASPLOS'19 PTX memory-model work (axiomatic model + Coq soundness proof) is the closest reusable proof artifact for fences/scopes.

This project's contribution: `Clang-LibTooling frontend + Rocq MiniCUDA→MiniHIP simulation proof + Rust-validated E2E`.

## 3. Scope

### 3.1 In scope (v1)

- CUDA **kernels + runtime API only** (see §4).
- Correctness-preserving translation + machine-checked core proof.
- Docker-based ROCm CI for build/run checks.

### 3.2 Out of scope (v1, fail closed — never silently supported)

- Performance parity, autotuning, occupancy/LDS/wave-size specialization, MFMA/WMMA selection.
- Any `asm()` / inline PTX (full ISA, including the common ~25-op subset — that lifter is v2).
- Libraries: cuBLAS/cuDNN/Thrust/CUB/cooperative groups/graphs/unified memory/textures/NCCL.
- Warp-collectives (`shfl.sync`, `ballot`, `vote`, `mma.sync`), non-block atomics/fences, inter-block communication, dynamic parallelism, exceptions/virtuals, `__CUDA_ARCH__`/warpSize-dependent branching.

`perf/` and `asm-lifter/` directories exist in v1 as **empty interface stubs only**.

## 4. Functional requirements

### FR-1 Accepted input language (frozen)

**Version ceiling (binding):** accepted CUDA language is **12.9.x**. Rationale: latest HIPIFY documents support **≤12.9.1**; latest NVIDIA **GA Toolkit is 13.3.1 (June 2026)** while **13.4.0 is Developer Preview (July 2026)** and `13.4.x` conda numbers are per-component versions, not a GA Toolkit. v1 therefore:

- Accepts the 12.9 language subset below.
- Compiles/tests with whatever GA `nvcc` is installed (13.3.1 acceptable as oracle).
- Rejects any 13.x-only construct (Tile-IR, new proxy usages, new headers/APIs) as `Unsupported(cuda13-only, loc)`.

**Accepted constructs:**

- Qualifiers: `__global__`, `__device__`, `__shared__`.
- Launch: `<<<grid, block[, stream]>>>`.
- Builtins: `threadIdx`, `blockIdx`, `blockDim`, `gridDim`.
- Host API: `cudaMalloc`, `cudaMemcpy`, `cudaMemset`, `cudaFree`, `cudaStreamCreate`, `cudaStreamSynchronize`, `cudaStreamDestroy`, `cudaEventCreate`, `cudaEventRecord`, `cudaEventSynchronize`, `cudaEventDestroy`, `cudaEventElapsedTime`, `cudaGetLastError`, `cudaGetErrorString`, `cudaSetDevice`, `cudaDeviceSynchronize`.
- Device: `__syncthreads`, block-scope `atomicAdd` (int/float), plain `for`/`if`, flat 1-D indexing, `float`/`double`/`int` scalars and 1-D arrays.

### FR-2 Mapping (proved, 1:1, no perf rewrites)

`cudaX → hipX` API table, `<<<>>> → hipLaunchKernelGGL`, index builtins identity, `__syncthreads → __syncthreads`, `atomicAdd → atomicAdd`. No arch-specific rewriting in the verified core.

### FR-3 Rejection policy

Anything outside FR-1 (including all of §3.2 and all 13.x-only syntax) MUST produce `Unsupported(feature, file:line:col, hint)` and emit **no output file**. Exit code 2. No guessing, no fallback emission.

### FR-4 Pipeline

```
.cu
 → [C++ Clang-LibTooling frontend] → MiniCUDA.json (schema v1)
 → [OCaml verified core (Rocq-extracted)] → MiniHIP.json (schema v1)
 → [printer] → .hip
 → [Rust validator] → report.json + exit code
```

Stages communicate **only** via versioned JSON-lines + exit codes. No shared heaps.

### FR-5 Diagnostics

Every success/failure prints `file:line:col: <reason> [<hint>]`. Exit codes: `0` ok, `2` unsupported-in-scope-reject, `3` internal error.

## 5. Verification requirements (the proof obligation)

### VR-1 Theorem (sole v1 proof obligation)

> For all `cu`, `mc`, `mh`: if `parse(cu) = OK(mc)`, `map_core(mc) = OK(mh)`, `WellFormed(mc)`, and `WellSync(mc)`, then `behaviors(mh) ⊆ behaviors(mc)`.

- `WellSync(k)`: data-race-free; all cross-thread sharing dominated by `__syncthreads`; no warp-collectives; no inter-block communication except completed launches/memcpy.
- `behaviors`: device-buffer contents, return/error codes, FIFO-stream + barrier-visible launch ordering.
- Numbers: integers bit-exact; floating point proved as same-op-order value preservation (cross-toolchain FP drift, per the Varity evidence class, is out-of-proof and must be surfaced by the validator tolerance report, never hidden).
- Concurrency method: SDV/GPUVerify-style 2-thread reduction; **no full weak-memory/scoped-atomics proof in v1**.

### VR-2 Proof-done criteria

`rocq make` green with `transpile_correct` ending in `Qed`, allowing **at most 2 named `Admitted` lemmas**, each tracked in `docs/ADMITS.md` with a v1.1 close-out plan. Prototype and proofs are developed in parallel; neither alone constitutes v1-done.

### VR-3 Stage-2 (stretch, non-blocking for v1)

LLVM-IR `nvptx64` vs `amdgcn` validation via `Vellvm` semantics reference + `Alive2 alive-tv` spot checks on loop-free kernels. If the custom-LLVM build cost exceeds the solo-weeks budget, this moves to v1.1 without invalidating the AST proof.

## 6. Architecture and language assignments

| Component | Language / build | Owns |
|---|---|---|
| Proofs | Rocq/Gallina 9.2.0, Platform 2026.07.0 | `rocq/MiniCuda.v`, `MiniHip.v`, `Map.v`, `Sim.v`, `transpile_correct` |
| Verified runtime | OCaml 4.14.1, Dune (opam) | Extracted `Map` + thin `Driver`; no hand logic on the mapped path |
| Frontend | C++17, Clang LibTooling, CMake | `frontend/`: ~10 AST matchers → `MiniCUDA.json`; HIPIFY matchers consulted as reference only |
| CLI + validator | Rust (Cargo): `clap` + `serde_json` + process orchestration | `cu2hip` binary: drives frontend→core→printer, parallel corpus runs, Docker-`hipcc` + host-`nvcc` differential, JSON reports; future home of v2 PTX lifter |
| Scripts only | Python (pip) | Corpus generation, CI glue — off the trusted path |
| Subject matter | CUDA/HIP C++ | `tests/corpus/*`: 8–10 in-scope kernels + `reject-*` negatives per FR-3 |
| v2 hooks | Rust traits / empty dirs | `perf/`, `asm-lifter/`: interfaces + `TODO-v2` only |

## 7. Repository layout (to be created)

```
cuda-rocm/
  README.md SRS.md dune-project .gitignore
  rocq/MiniCuda.v MiniHip.v Map.v Sim.v Extract.v _RocqProject
  core/{lib/{extracted,minijson},bin/minimap} (dune; driver wraps extraction)
  frontend/cu2mini.cpp (cmake, clang matchers → MiniCUDA.json)
  cli/ (cargo: cu2hip + differential runner)
  printer/hip_print.ml (MiniHIP.json → .hip; small, reviewed, unproved)
  tests/corpus/{vectorAdd,saxpy}.cu (+ .expected.md)
  tests/extra/reduce-shared.cu (outside proved fragment)
  tests/reject/{asm,device-fn,warp,loop,cuda-header}.cu
  tests/fixtures/*.json tests/expected/*.hip tests/shim/ tests/run_e2e.sh
  docker/rocm714/{Dockerfile,ci.sh} .github/workflows/ci.yml
  docs/{SUPPORTED,API,VERSIONS,ADMITS,ROADMAP,EXTEND-perf-asm}.md
  perf/TODO-v2.md asm-lifter/TODO-v2.md (v2 stubs)
```

## 8. External interfaces and version pins (binding)

| Item | Pin |
|---|---|
| Rocq | 9.2.0, Platform 2026.07.0, OCaml 4.14.1, opam ≥ 2.1 |
| CUDA input language | 12.9.x (13.x-only → reject) |
| Host oracle | GA `nvcc` as installed (13.3.1 known-good); local `clang` |
| ROCm CI | `7.14.0` (2026-07-15, TheRock modular); image digest recorded in `docker/`; `hipcc --offload-arch=gfx90a,gfx942` |
| HIPIFY reference | 18.x, `amd-develop` branch (oracle only, not a build dependency) |
| Clang for frontend | version matched to CUDA-12.9 support per HIPIFY table |
| JSON schema | `Mini*.json` schema `v1`, versioned field required |

CLI contract: `cu2hip [--arch gfx90a,gfx942] in.cu -o out.hip --report report.json`.

## 9. Validation and acceptance (all must hold)

1. `rocq make` green per VR-2.
2. Corpus: all in-scope kernels transpile; ≥6/8 compile in the ROCm 7.14 container; host-`nvcc` vs container-`hipcc` buffers match (int exact; fp reported with tolerance, drift flagged).
3. Negative suite: each FR-3/§3.2 case (including a `cuda13-only` probe) yields `Unsupported(loc)`, zero output.
4. CI pipeline `frontend → core → cli → corpus + rejects → docker hipcc check` is green; `SUPPORTED.md` matches implementation exactly.
5. `docs/ADMITS.md` (≤2 entries or empty) and `docs/EXTEND-perf-asm.md` present.

## 10. Schedule (solo PoC, weeks)

- **W1 bootstrap+freeze:** toolchains (opam Rocq, Cargo, CMake/Clang), HIPIFY reference checkout, ROCm 7.14 image pull, `SUPPORTED.md` freeze, 2 kernels E2E (vectorAdd, saxpy) compiling in Docker; Rocq stubs admit-green.
- **W2 core+proof:** semantics + `map_*` + simulation lemmas + `transpile_correct`; extraction wired; 8-kernel corpus transpile.
- **W3 validator:** Rust differential runner, reject suite, Docker `hipcc` + host `nvcc` comparison, `alive-tv` stretch if cheap.
- **W4 harden:** close admits or cut scope to keep `Qed`; freeze pins + digests; v2 hook docs.

## 11. Risks and mitigations

- **HIPIFY ceiling (12.9) vs Toolkit 13.x:** enforced by FR-1 gate + `cuda13-only` reject tests.
- **Solo + 4 toolchains (opam/Cargo/CMake/pip):** isolated per-directory builds, JSON-only boundaries, per-layer Docker caching.
- **No local AMD GPU:** execution signal only where a GPU runner exists; otherwise container build-check + host-`nvcc`/CPU reference.
- **Rocq ramp-up:** tiny AST, automation (`lia/auto`), tracked admits instead of scope creep.
- **FP divergence class:** acknowledged from the literature; validator reports it, proof does not claim it away.

## 12. Traceability

Each FR/VR maps to: Rocq lemma or test in `tests/` and a row in `docs/SUPPORTED.md`. No requirement without a test or proof artifact; no implementation beyond this SRS in v1.
