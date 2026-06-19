# Roadmap — Verified CUDA → HIP PoC

Source of truth for scope: `SRS.md`. API rules: skill `api-practices`
(`docs/API.md` updated in the same change as any API).

## Goal flow (DAG)

```
G0 bootstrap ──┬──> G1 schemas ──┬──> G2 C++ frontend ──┐
               │                  │                      ├──> G5 Rust CLI/validator ──> G6 Docker CI ──> G7 release
               │                  └──> G3 Rocq core ───> G4 OCaml driver/printer ──┘
```

- G1 unblocks G2 and G3 in parallel (prototype + proofs simultaneously).
- G5 needs at least stub outputs from G2 and G4 to integrate against.
- G6 needs G5 + a compilable corpus kernel.
- G7 runs acceptance per SRS §9.

## G0 — Bootstrap & freeze

- Install: opam Rocq 9.2.0 / Platform 2026.07.0, OCaml 4.14.1, Cargo, CMake + Clang (CUDA-12.9-compatible), pip.
- Checkout `ROCm/HIPIFY amd-develop` as reference oracle only; pull ROCm 7.14 image, record digest.
- Write `docs/SUPPORTED.md` (subset table + API map, mirrors SRS §4 FR-1/FR-2).
- Seed corpus: `vectorAdd`, `saxpy` (.cu + expected behavior notes).
- **Exit:** `docs/SUPPORTED.md` frozen; versions recorded; 2 seed kernels present.

## G1 — Contracts: schemas + fixtures

- Define `MiniCUDA.json` / `MiniHIP.json` schema v1 (version field required).
- Hand-write JSON fixtures for `vectorAdd` (+ one `Unsupported` fixture, e.g. `asm()`).
- Register schemas + CLI contract in `docs/API.md` (per skill `api-practices`).
- **Exit:** fixtures validate against schema; G2/G3 code to the fixtures, not to each other.

## G2 — C++ frontend (LibTooling matchers → MiniCUDA.json)

- ~10 matchers: `__global__` launches, `cudaMalloc/Memcpy/Memset/Free`, stream/event calls, `threadIdx/blockIdx/blockDim/gridDim`, `__syncthreads`, block `atomicAdd`.
- Everything else → `Unsupported(feature, file:line:col, hint)`; exit 2; no output file.
- **Exit:** seed kernels emit fixture-matching JSON; each FR-3 reject probe errors with loc.

## G3 — Rocq core (the proof)

- `rocq/`: `MiniCuda.v`, `MiniHip.v` (AST mirrors JSON schema 1:1), small-step semantics, `Map.v` (`map_kernel`/`map_api`), `Sim.v` (`transpile_correct`, SRS §5 VR-1) over `WellSync` kernels.
- Max 2 named `Admitted` lemmas, tracked in `docs/ADMITS.md`.
- Extract to OCaml.
- **Exit:** `rocq make` green; theorem `Qed` (modulo tracked admits).

## G4 — OCaml driver + printer (MiniHIP.json → .hip)

- Dune `core/`: wraps extracted `Map`; `printer/`: JSON → `.hip` (small, reviewed, unproved).
- **Exit:** `vectorAdd` JSON → `.hip` compiles conceptually (full compile check in G6).

## G5 — Rust CLI + validator

- `cu2hip [--arch …] in.cu -o out.hip --report report.json` orchestrates frontend → core → printer.
- Parallel corpus runner; host-`nvcc` vs container-`hipcc` differential (int exact; fp tolerance reported, drift flagged per SRS §5).
- **Exit:** corpus + reject suite run with one command; JSON reports emitted.

## G6 — Docker ROCm 7.14 CI

- `docker/rocm714/Dockerfile` pinned (digest recorded); CI stages: frontend build → core build → cli build → corpus + rejects → `hipcc --offload-arch=gfx90a,gfx942` check; GPU execution where a runner exists, else build-check + host reference.
- **Exit:** green CI on a machine with the image; GPU-run results recorded where available.

## G7 — Harden + PoC release

- Close admits or cut scope to keep `Qed`; freeze all pins/digests.
- Docs complete: `SUPPORTED.md` ≡ implementation, `API.md` complete, `ADMITS.md` (≤2 or empty), `EXTEND-perf-asm.md` v2 hooks.
- Run SRS §9 acceptance 1–5; tag release.
- **Exit:** all five acceptance items green.

## Non-goals (v1)

Perf parity/autotuning, any `asm()`/PTX lifting, libraries, graphs, unified
memory, warp-collectives, full weak-memory proof, verified parser, `alive-tv`
beyond stretch. Stubs only in `perf/`, `asm-lifter/`.
