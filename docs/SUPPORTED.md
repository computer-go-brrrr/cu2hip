# SUPPORTED — Frozen v1 Subset (mirrors SRS §4)

Anything not listed here is rejected with `Unsupported(feature, file:line:col, hint)`,
exit code 2, and no output file. This file MUST match the implementation exactly
(ROADMAP G7 acceptance item 4).

**Input language ceiling: CUDA 12.9.x.** Host oracle is newer (see `VERSIONS.md`);
13.x-only constructs are rejected, never mapped.

## Kernels

| Construct | CUDA form | HIP form | Notes |
|---|---|---|---|
| Kernel def | `__global__ void k(...)` | `__global__ void k(...)` | identity |
| Device fn | `__device__ T f(...)` | rejected in v1 (`device-functions`) | retargeted to v1.1: schema v1 has no node; inline helpers for v1 |
| Shared mem | `__shared__ T x[N]` | `__shared__ T x[N]` | constant-size scalar arrays only; collected to kernel.shared and re-emitted; transpileable but OUTSIDE the proved fragment (`WellSync` requires `shared=[]`) |
| Launch | `k<<<grid, block[, stream]>>>` | `hipLaunchKernelGGL(k, grid, block, 0, stream, ...)` | 1-D configurations in v1 corpus |
| Thread idx | `threadIdx.x`, `blockIdx.x`, `blockDim.x`, `gridDim.x` | identity | `.y`/`.z` accepted, corpus is 1-D |
| Barrier | `__syncthreads()` | `__syncthreads()` | block scope; sole cross-thread sync primitive |
| Block atomic | `atomicAdd(&x, v)` int/float | `atomicAdd(&x, v)` | block scope only |

## Host runtime API map (all 1:1, FIFO stream semantics)

| CUDA | HIP | Notes |
|---|---|---|
| `cudaMalloc` | `hipMalloc` | |
| `cudaMemcpy` | `hipMemcpy` | `cudaMemcpyKind` → `hipMemcpyKind` enum map |
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
| `cudaSetDevice` | `hipSetDevice` | single-device programs in v1 corpus |
| `cudaDeviceSynchronize` | `hipDeviceSynchronize` | |

Headers: `<cuda_runtime.h>` → `<hip/hip_runtime.h>`. Error type `cudaError_t` →
`hipError_t` (NOT an alias; converter noted at use sites).

## Types / language

`float`, `double`, `int`, 1-D arrays; flat 1-D indexing.
`if` in kernels (with array-bracketed `then`/`else`); kernel `for`/`while`
rejected (`loops`). `for`/`if` in host glue pass through opaquely as
`host_code` (byte-identical, semicolon-captured).
`dim3` with `(x,1,1)` in corpus (single-arg construction unwraps;
multi-arg rejected).
`sizeof` on `int`/`float` (= 4) and `double` (= 8) evaluates (LP64 ABI).

`host_code` MUST NOT mention CUDA-ecosystem APIs (enforced:
`host-cuda-leak` reject on `cuda/cublas/cusparse/cufft/curand/cusolver/
cudnn/thrust::/cooperative_groups/nccl/NCCL` substrings; fail-closed
over comment-text false positives).

## Rejected (non-exhaustive, each with hint)

`asm()`/any PTX; `__shfl_sync`, `__ballot_sync`, `__any_sync`/`__all_sync`,
`cooperative_groups`, `mma.sync`/WMMA, graphs, unified/virtual memory,
textures/surfaces, `cudaStreamAddCallback`, NCCL, any `cublas*/cudnn*/thrust`
include or call, `__CUDA_ARCH__` branches, `warpSize`-dependent indexing,
dynamic parallelism, exceptions/RTTI/virtuals in device code, and every
13.x-only construct (Tile-IR, new proxy fences, new headers/APIs).

Conditional compilation (`#if`/`#ifdef`, incl. `__CUDA_ARCH__` branches) is
evaluated once for the frontend's fixed target (`--arch`, default `sm_86`);
untaken branches are invisible, exactly as in a single-arch nvcc compile.
Multi-arch variant selection is out of scope for v1.
