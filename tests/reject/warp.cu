#include <cuda_runtime.h>

__global__ void k(float *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) {
    float v = d[i];
    float s = __shfl_down_sync(0xffffffff, v, 1);
    d[i] = s;
  }
}

int main() { return 0; }
