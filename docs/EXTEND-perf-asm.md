# EXTEND — v2 hooks: performance + inline-PTX lifter

Both are EXPLICITLY out of v1 scope. This file reserves their interfaces
so v2 does not refactor the verified core. Nothing here is implemented;
`perf/` and `asm-lifter/` contain only TODO stubs.

## Design constraint (binding on v2)

Performance optimization and asm lifting MUST live OUTSIDE the verified
`Map.map_program` core, as separate stages:

```
.cu -> cu2mini -> minimap (VERIFIED, frozen) -> opt/perf stage (v2) -> hip_print -> .hip
                                                    |
                    asm-lifter (v2): MiniCUDA.json --+ (replaces Unsupported[inline-asm]
                                                       nodes with portable HIP subprograms)
```

Rationale: `transpile_correct` proves the core mapping preserves behaviors.
A perf stage that rewrites kernels would need its OWN preservation proof
(or translation validation per kernel via alive-tv on LLVM IR). Never
weaken the core to gain speed.

## Perf stage (v2) — planned interface

- Input/output: `MiniHIP.json` v1 (same schema; new schema version only if
  shapes change, per skill `api-practices`).
- Candidate transforms (each behind a flag, validated by differential runs
  + `rocprof-compute` on gfx90a/gfx942):
  - wavefront-size specialization (32 vs 64) and launch-bounds tuning
  - LDS padding/bank-conflict avoidance for `__shared__` kernels
  - `rocWMMA` selection for `mma.sync`-class patterns (after asm-lifter)
  - occupancy-driven block-size search (autotuner loop in `cu2hip`)
- Acceptance: parity-or-better vs `hipify` baseline on an expanded corpus,
  with per-kernel `alive-tv` refinement checks where feasible.

## asm-lifter (v2) — planned interface

- Input: `asm()` sites rejected today (`inline-asm` diagnostic with loc).
- Strategy: pattern table for the common ~25 PTX ops
  (`mov/add/mul/mad/ld/st/membar/bar.sync/shfl/ballot/vote/setp`) to HIP
  intrinsics (`__shfl_sync`, `__ballot_sync`, `__threadfence_*`,
  `rocWMMA`), special-reg mapping (`%tid.x` -> `threadIdx.x`, ...),
  constraint checking (`=r`/`r`/`l` type-size rules per the PTX spec).
- Anything outside the table keeps failing closed with a diagnostic.
- The lifter's output must itself satisfy `WellFormedCuda`-style checks;
  extending `transpile_correct` to cover lifted fragments is a
  research-grade work item (PTX memory-model mapping à la Lustig et al.).

## Non-goals carried forward

Libraries (cuBLAS/cuDNN/Thrust), graphs, cooperative groups, unified
memory, multi-arch `#if` variant selection — each needs its own SRS
amendment before work starts.
