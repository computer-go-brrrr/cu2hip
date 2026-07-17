#include <cuda_runtime.h>

__device__ float sq(float x) { return x * x; }

__global__ void k(float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) d[i] = sq((float)i);
}

int main() { return 0; }
