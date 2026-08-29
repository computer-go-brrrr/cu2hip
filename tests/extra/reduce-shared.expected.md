# reduce-shared — EXTRA (outside the proved fragment, pipeline-tested only)

- Block sum using `__shared__ float tile[256]` + `__syncthreads()`.
- Frontend collects the shared decl into the kernel's `shared` list;
  the printer re-emits it. `WellSync` requires `shared = []`, so this
  kernel transpiles but is EXCLUDED from `transpile_correct` (see
  SUPPORTED.md, rocq/README.md). Kept here (not in tests/corpus) so the
  corpus stays exactly the proved fragment.
- Behavior: out[0] = g[0] = 1. Prints PASS, exits 0.
