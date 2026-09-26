# cu2mini — C++ frontend (G2)

Clang-LibTooling tool: CUDA subset → `MiniCUDA.json` (schema `minicuda/v1`).

## Build

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```
(prefer `make frontend` from the repo root; same commands via the Makefile).

Requires Clang/LLVM dev files (`libclang-cpp`, ASTMatchers/Tooling headers)
and a CUDA toolkit for headers (`--cuda-path`, default `/opt/cuda`).

On systems with several Clang installs, pin the discovery explicitly
(CI hit a half-installed system clang-18 shadowing clang-22 otherwise):

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_DIR=/usr/lib/llvm-22/lib/cmake/llvm \
  -DClang_DIR=/usr/lib/llvm-22/lib/cmake/clang
```

## Run

```sh
./build/cu2mini <in.cu> -o <out.json> [--cuda-path P] [--arch sm_XX] [--resource-dir D]
```

Exit codes: `0` ok · `2` unsupported input (`program: null` + `diagnostics`,
one entry per site) · `3` internal error (ClangTool failure, bad CLI, no output).

Fixed parse flags: `-std=c++17 --cuda-device-only --cuda-gpu-arch=<arch>`
plus an explicit `-resource-dir` (default `/usr/lib/clang/22`; distro
packages such as Ubuntu's `clang-22` use e.g.
`/usr/lib/llvm-22/lib/clang/22` — pass it explicitly or the CUDA wrapper
header is not found, since the tool binary is not the clang driver).

## Conversion rules (fail closed)

- Kernels (`__global__` defs in the main file): params must be
  `int/float/double` or pointers thereto; body allows `let` (initialized
  scalar locals), `store`, `if`, `__syncthreads()`, `atomicAdd()` statements.
  Loops, switches, gotos, valued returns, multi-decls, non-scalar locals →
  `Unsupported` with loc.
- Host functions: `cuda*` API calls (SUPPORTED.md set) and `<<<>>>` launches
  become nodes; **every other host statement passes through byte-identical as
  `host_code`** (declarations, init/check loops, `printf`). `host_code`
  MUST NOT contain `cuda*` identifiers (checker-enforced on fixtures).
- `__device__` definitions → `device-functions` (retargeted to v1.1).
- `asm` statements (host or device) → `inline-asm` via TU-wide matcher.
- Warp collectives (`__shfl*`, `__ballot*`, `__any/all_sync`, `__activemask`,
  `__match_*`) → `warp-collective` via TU-wide matcher; conversion sites skip
  silently so each site yields exactly one diagnostic.
- Calls to `__device__` helpers inside kernels → `device-functions`.
- All other kernel expressions/statements → generic `bad-*` reject with loc.
  No guessing, no partial output: any blocking diagnostic ⇒ `program: null`.

## `host_code` fidelity rules

- Statements print from token ranges EXTENDED to swallow one following
  `;`, so reprinted code is verbatim-compilable (fixes inner `++bad;`,
  `printf(...);`, `delete[]...;`, `return ...;` which token ranges drop).
- Non-CUDA `#include` lines are captured textually in `main()` (matchers
  can't see preprocessor directives) and prepended as `host_code` nodes;
  `cuda_runtime.h` is mapped to the HIP header instead; other `cuda*`
  headers are rejected (`unsupported-include`, they imply out-of-scope APIs).
- `host_code` text is scanned for CUDA-ecosystem API substrings
  (`host-cuda-leak` reject on cuda/cublas/cusparse/cufft/curand/cusolver/
  cudnn/thrust::/cooperative_groups/nccl). Without this, identifiers like
  `cudaError_t` would pass through unmapped and miscompile silently.
- `sizeof(int/float)` = 4, `sizeof(double)` = 8 (LP64 ABI); all other
  `sizeof` forms rejected.

## Robustness rules (from crash bugs found in testing)

- NEVER `dyn_cast` a possibly-null `strip()` result (asserts in debug,
  UB in release): `BuiltinFnToFnPtr` casts (builtin callees such as
  `__syncthreads` in device mode) legitimately fail stripping. Use the
  null-safe `asDeclRef` helper at every callee site.
- `if` branches always emit array-bracketed lists (`"else": [...]`, never
  `[[]]`); `tests/check_fixtures.py` asserts node shapes so emission bugs
  surface at the gate, not in the driver.

## Clang-shape notes (verified against Clang 22 + CUDA 13.4 headers)

- `blockIdx.x` etc. arrive as `PseudoObjectExpr` around
  `.__fetch_builtin_{x,y,z}` member calls (`MSPropertyRefExpr` sugar).
  Recovered by subtree search; anything else in that position is rejected.
- Launch configs arrive wrapped in single-arg `dim3` construction
  (`ConstructorConversion` → `CXXConstructExpr` with defaulted y/z
  `CXXDefaultArgExpr` children). Only the 1-real-arg form unwraps;
  multi-arg `dim3` is rejected.
- Kernel index arithmetic arrives as `unsigned int` with an outer
  `IntegralCast` to `int`. Elided (see proof obligation below).

## Proof obligations carried into G3 (Rocq)

1. **Index-cast elision:** 32-bit unsigned`<->`int `IntegralCast`s are dropped
   by the converter. Sound iff thread indices are in-bounds (`< 2^31`),
   making the conversion the identity. `WellSync` must imply in-bounds
   launches, or the theorem must bound the behavior to in-bounds executions.
2. **Builtin denotation:** `threadIdx.x` etc. must denote the same values in
   `MiniCuda` and `MiniHip` semantics (they print identically; the proof must
   give them identical meaning — in particular across 32/64-bit targets).
3. **`host_code` opacity:** passthrough text is byte-identical and contains no
   `cuda*` identifiers; the simulation theorem covers modeled nodes only and
   must state the passthrough assumption explicitly.
