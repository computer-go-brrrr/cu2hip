# printer/ — MiniHIP.json -> .hip (G4)

Unverified shell (reviewed + golden-tested): `hip_print <in.minihip.json>
-o <out.hip>`, exit 0 ok / 3 contract error.

## Emission rules

- File top: `#include <hip/hip_runtime.h>`, then `host_code` nodes whose
  text is an `#include` (hoisted; they arrive first anyway), then kernels,
  then `int main() {` + remaining host nodes in order + `}`.
- Kernels print 1:1 (`__global__`, params, `let`/`store`/`if`/`__syncthreads`,
  calls). Binops always parenthesized (semantics-preserving).
- Launches become
  `hipLaunchKernelGGL(k, dim3(grid), dim3(block), 0, stream-or-0, args...);`
  per the frozen SRS mapping.
- `hipMemcpy` regains its kind 4th argument from the JSON `copyKind`.
- `host_code` prints verbatim (frontend guarantees compilability, incl.
  trailing `;` capture — see `frontend/README.md`).

## Known v1 limitation

`EFloat` literals print with `%g`, plus a `.0` suffix when
integral-looking. The `f`-suffix (fp32) vs bare (fp64) distinction is not
tracked in schema v1; the v1 corpus has no kernel float literals.
Revisit with type-qualified literals in v1.1.

## Golden tests

`tests/expected/*.hip` are reviewed frozen outputs; `tests/run_e2e.sh`
diffs byte-identically. `tests/shim/` (test-only) maps the v1 HIP surface
back onto CUDA so goldens additionally execute on NVIDIA hardware.
