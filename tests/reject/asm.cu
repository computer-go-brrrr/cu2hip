#include <cuda_runtime.h>

__global__ void shfl(int *d, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  int v = 0;
  asm("mov.s32 %0, %1;" : "=r"(v) : "r"(i));
  if (i < n) d[i] = v;
}

int main() { return 0; }
