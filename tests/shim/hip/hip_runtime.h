// TEST-ONLY shim: lets transpiled .hip run on NVIDIA hardware for
// differential validation. NOT part of the product, NOT a HIP
// implementation. Maps the v1 HIP surface 1:1 back onto CUDA so the
// *emitted kernel bodies and host glue* can be executed and checked.
// A real HIP check (hipcc, AMD GPU) happens at G6.
#pragma once
#include <cuda_runtime.h>

#define hipMalloc cudaMalloc
#define hipMemcpy cudaMemcpy
#define hipMemset cudaMemset
#define hipFree cudaFree
#define hipStreamCreate cudaStreamCreate
#define hipStreamSynchronize cudaStreamSynchronize
#define hipStreamDestroy cudaStreamDestroy
#define hipEventCreate cudaEventCreate
#define hipEventRecord cudaEventRecord
#define hipEventSynchronize cudaEventSynchronize
#define hipEventDestroy cudaEventDestroy
#define hipEventElapsedTime cudaEventElapsedTime
#define hipGetLastError cudaGetLastError
#define hipGetErrorString cudaGetErrorString
#define hipSetDevice cudaSetDevice
#define hipDeviceSynchronize cudaDeviceSynchronize
#define hipMemcpyHostToDevice cudaMemcpyHostToDevice
#define hipMemcpyDeviceToHost cudaMemcpyDeviceToHost
#define hipMemcpyDeviceToDevice cudaMemcpyDeviceToDevice
#define hipMemcpyHostToHost cudaMemcpyHostToHost
#define hipLaunchKernelGGL(f, grid, block, shmem, stream, ...) \
  f<<<grid, block, shmem, stream>>>(__VA_ARGS__)
