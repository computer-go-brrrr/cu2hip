#include <cuda_runtime.h>

__global__ void k(float *d, int n) {
  for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += blockDim.x * gridDim.x)
    d[i] = 0.0f;
}

int main() { return 0; }
