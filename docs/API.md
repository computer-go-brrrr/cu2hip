# API Reference

Canonical record of every public API in this repo (see skill `api-practices`).
Rule: an API without an entry here does not exist — the change that introduces
or modifies an API MUST update this file in the same change.

## Conventions

- Exit codes everywhere: `0` ok, `2` unsupported input (with `file:line:col`
  + hint), `3` internal error.
- Stage wire format: versioned JSON-lines, `Mini*.json` schema `v1`.

## Schemas

| Schema          | Version | Producer              | Consumer            | Status |
|-----------------|---------|-----------------------|---------------------|--------|
| `MiniCUDA.json` | v1 (`schemas/minicuda-v1.schema.json`) | C++ frontend | OCaml verified core | defined (G1) |
| `MiniHIP.json` | v1 (`schemas/minihip-v1.schema.json`) | OCaml verified core | printer / validator | defined (G1) |

## CLI

| Command    | Purpose | Status |
|------------|---------|--------|
| `cu2hip [--arch <archs>] [--cuda-path P] [--resource-dir D] <in.cu> -o <out.hip> --report <report.json>` | End-to-end transpilation driver | defined (G5) |
| `cu2mini <in.cu> -o <out.json> [--cuda-path P] [--arch sm_XX] [--resource-dir D]` | Stage tool: CUDA subset → MiniCUDA.json; exits 0/2/3 | defined (G2) |
| `minimap <in.minicuda.json> -o <out.minihip.json>` | Stage tool: runs EXTRACTED `Map.map_program`; exits 0/2/3 | defined (G4) |
| `hip_print <in.minihip.json> -o <out.hip>` | Stage tool: MiniHIP.json → .hip; exit 0/3 | defined (G4) |

## Host runtime API map (v1, frozen — mirrors `SUPPORTED.md`)

All mappings 1:1, FIFO stream semantics. Header `<cuda_runtime.h>` →
`<hip/hip_runtime.h>`; `cudaError_t` → `hipError_t` (not an alias).

| CUDA | HIP | Notes |
|---|---|---|
| `cudaMalloc` | `hipMalloc` | |
| `cudaMemcpy` | `hipMemcpy` | `cudaMemcpyKind` → `hipMemcpyKind` |
| `cudaMemset` | `hipMemset` | |
| `cudaFree` | `hipFree` | |
| `cudaStreamCreate` | `hipStreamCreate` | no callbacks |
| `cudaStreamSynchronize` | `hipStreamSynchronize` | |
| `cudaStreamDestroy` | `hipStreamDestroy` | |
| `cudaEventCreate` | `hipEventCreate` | |
| `cudaEventRecord` | `hipEventRecord` | |
| `cudaEventSynchronize` | `hipEventSynchronize` | |
| `cudaEventDestroy` | `hipEventDestroy` | |
| `cudaEventElapsedTime` | `hipEventElapsedTime` | |
| `cudaGetLastError` | `hipGetLastError` | |
| `cudaGetErrorString` | `hipGetErrorString` | |
| `cudaSetDevice` | `hipSetDevice` | single-device v1 corpus |
| `cudaDeviceSynchronize` | `hipDeviceSynchronize` | |

Kernel constructs mapped 1:1: `__global__`, `__device__`, `__shared__`,
`<<<grid, block[, stream]>>>` → `hipLaunchKernelGGL`, thread-index builtins,
`__syncthreads`, block-scope `atomicAdd`.

## Libraries (per language)

_Fill in as components land. One row per public symbol: signature, purpose,
parameters, returns, errors, minimal example._

| Symbol | Language | Signature | Purpose | Errors | Status |
|--------|----------|-----------|---------|--------|--------|
| `transpile_correct` | Rocq (`rocq/Sim.v`) | `forall mc mh he hm gm, map_program mc = Some mh -> WellFormedCuda mc -> WellSync mc -> run_program mc he hm gm = run_program mh he hm gm /\ pheader mh = hip_header` | The v1 correctness theorem: identical event traces + HIP header | n/a (proof) | `Qed`, zero admits |
| `map_program` | Rocq (`rocq/Map.v`) | `program -> option program` | Verified core mapping: renames 16 APIs + header, copies shapes | `None` on unknown API | proved (`classify_map`, shape-identity lemmas) |
| `run_program` | Rocq (`rocq/MiniCuda.v`) | `program -> env -> hmem -> gmem -> option (list event * hmem * gmem)` | Executable semantics behaviors are compared with | `None` = stuck (no behavior) | model |
| `classify` | Rocq (`rocq/MiniCuda.v`) | `string -> apiOp` | Vendor-neutral API classification; both `cuda*`/`hip*` map to same op | `OpOther` = stuck | model |

## Change log

| Date       | API change | Author |
|------------|------------|--------|
| 2026-09-20 | File created (stub) | — |
| 2026-09-20 | v1 host runtime API map frozen (16 entries, mirrors SUPPORTED.md) | G0 |
| 2026-09-20 | MiniCUDA/MiniHIP schema v1 defined + 4 fixtures + checker | G1 |
| 2026-09-20 | cu2mini stage tool defined; __device__ moved to v1.1 in SUPPORTED.md | G2 |
| 2026-09-20 | Rocq core API registered (transpile_correct Qed, zero admits) | G3 |
| 2026-09-20 | minimap + hip_print defined; E2E green incl. GPU shim runs | G4 |
| 2026-09-20 | cu2hip CLI + report/v1 + shim differential defined | G5 |
| 2026-09-20 | cu2hip --cuda-path flag; report/v1 gains cuda_path; CI installs Clang 22 + CUDA 12.9, regenerates Rocq Makefile | CI fix |
| 2026-09-20 | --resource-dir flag (cu2mini/cu2hip/run_e2e) for distro Clang layouts | CI fix |
| 2026-09-20 | --version on all four binaries; scripts/make-release.sh packs dist tarball; dune needs @all to recurse | Release |
| 2026-09-20 | G2 hardening: host-cuda-leak/unsupported-include diagnostics, __shared__ collect+emit (outside proof), sizeof(int/float/double), semicolon capture | G6/G7 |
