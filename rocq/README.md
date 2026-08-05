# rocq/ — verified core (G3)

Rocq 9.2 proof of semantic preservation for the v1 transpiler.

## Build

```sh
eval $(opam env --switch=cuda-rocm-rocq)
rocq makefile -f _RocqProject -o Makefile   # regenerate (Makefile* is gitignored)
make vos && make        # .vos first (Rocq 9 dependency flow), then .vo
```

## Files

| File | Contents |
|---|---|
| `MiniCuda.v` | MiniCUDA AST (mirrors `minicuda-v1.schema.json`), executable semantics (`eval_*`, `run_threads`, `run_host`), `classify`, well-formedness |
| `MiniHip.v` | HIP instantiation: header + 16-name API sets + `WellFormedCuda/Hip` |
| `Map.v` | `mapApi` table, structural `map_*`, `classify_map`, shape-identity lemmas |
| `Sim.v` | `WellSync`, `run_host_map`, **`transpile_correct`** |

## Status

`transpile_correct : Qed`, **zero admits** (see `docs/ADMITS.md`).
`Print Assumptions` shows only `PrimFloat.*` kernel primitives (IEEE-754
implementation TCB, same class as CompCert's trusted numerics).

## Model assumptions (carried as documentation, not axioms)

1. **Ints are Z** (unbounded). Frontend elides 32-bit uint`<->`int casts;
   sound for in-bounds (`< 2^31`) executions; out-of-bounds gets stuck
   (no behavior) on both sides.
2. **Floats are binary64** (`PrimFloat`). Preservation holds regardless of
   width because both sides apply identical ops; fp32-vs-fp64 vs silicon
   is a documented frontend gap, not a preservation gap.
3. **Threads fold sequentially** over shared `gmem`. Faithful only on
   race-free programs — enforced by the `WellSync` hypothesis (v1: no
   `__shared__`; global disjointness assumed for flat thread-indexed code,
   per-kernel injectivity checking is future work). Kernels DECLARING
   `__shared__` transpile (frontend collects, printer re-emits) but are
   explicitly OUTSIDE `transpile_correct`; they live in `tests/extra/`,
   never in `tests/corpus/`.
4. **`host_code` is opaque**: byte-identical passthrough; initial host
   env/memories universally quantified; exit codes unmodeled.
5. **Builtins on host denote 0**; y/z dims denote 0 (corpus is 1-D).
6. **memcpy/memset granularity is 4 bytes** with exact division required
   (stuck otherwise); D2D/H2H stuck; mixed int/float binops stuck;
   float conditions stuck; `malloc` binds `VPtr <varname>` (infinite
   zero-init memory model; `free` is effect-free).
