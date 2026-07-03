# vectorAdd — behavior note

- Computes `c[i] = a[i] + b[i]` for `n = 1024`, with `a[i] = i`, `b[i] = 2i`,
  so `c[i] = 3i`. Prints `PASS`, exits 0 on success.
- Launch: 4 blocks × 256 threads, 1-D. No shared memory, no atomics.
- `WellSync` argument: each thread writes exactly one distinct global index;
  no cross-thread reads; `cudaDeviceSynchronize` separates launch from D2H copy.
  Race-free by disjointness.
- Expected HIP output: `<cuda_runtime.h>` → `<hip/hip_runtime.h>`,
  `cuda*` → `hip*` per `docs/SUPPORTED.md`; kernel body unchanged.
