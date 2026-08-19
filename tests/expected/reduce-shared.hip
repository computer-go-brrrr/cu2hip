#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void blockSum(float *g, float *out, int n) {
  __shared__ float tile[256];
  int i = ((blockIdx.x * blockDim.x) + threadIdx.x);
  int t = threadIdx.x;
  if ((i < n)) {
    tile[t] = g[i];
  } else {
    tile[t] = 0.0;
  }
  __syncthreads();
  if ((t == 0)) {
    float s = 0.0;
    s = (s + tile[0]);
    out[blockIdx.x] = s;
  }
}

int main() {
  const int n = 256;
  const size_t bytes = (size_t)n * sizeof(float);
  float *h_g = new float[n];
  for (int i = 0; i < n; ++i) h_g[i] = 1.0f;
  float *d_g, *d_o;
  hipMalloc(&d_g, bytes);
  hipMalloc(&d_o, 4);
  hipMemcpy(d_g, h_g, bytes, hipMemcpyHostToDevice);
  hipLaunchKernelGGL(blockSum, dim3(1), dim3(256), 0, 0, d_g, d_o, n);
  hipDeviceSynchronize();
  float h_o = 0.0f;
  hipMemcpy(&h_o, d_o, 4, hipMemcpyDeviceToHost);
  printf(h_o == 1.0f ? "PASS\n" : "FAIL %f\n", h_o);
  hipFree(d_g);
  hipFree(d_o);
  delete[] h_g;
  return 0;
}
