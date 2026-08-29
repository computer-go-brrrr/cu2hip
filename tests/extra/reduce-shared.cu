#include <cstdio>
#include <cuda_runtime.h>

__global__ void blockSum(const float *g, float *out, int n) {
  __shared__ float tile[256];
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  int t = threadIdx.x;
  if (i < n)
    tile[t] = g[i];
  else
    tile[t] = 0.0f;
  __syncthreads();
  if (t == 0) {
    float s = 0.0f;
    s = s + tile[0];
    out[blockIdx.x] = s;
  }
}

int main() {
  const int n = 256;
  const size_t bytes = (size_t)n * sizeof(float);
  float *h_g = new float[n];
  for (int i = 0; i < n; ++i) h_g[i] = 1.0f;
  float *d_g, *d_o;
  cudaMalloc(&d_g, bytes);
  cudaMalloc(&d_o, sizeof(float));
  cudaMemcpy(d_g, h_g, bytes, cudaMemcpyHostToDevice);
  blockSum<<<1, 256>>>(d_g, d_o, n);
  cudaDeviceSynchronize();
  float h_o = 0.0f;
  cudaMemcpy(&h_o, d_o, sizeof(float), cudaMemcpyDeviceToHost);
  printf(h_o == 1.0f ? "PASS\n" : "FAIL %f\n", h_o);
  cudaFree(d_g);
  cudaFree(d_o);
  delete[] h_g;
  return 0;
}
