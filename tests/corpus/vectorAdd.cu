#include <cuda_runtime.h>
#include <cstdio>

__global__ void vecAdd(const float *a, const float *b, float *c, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) c[i] = a[i] + b[i];
}

int main() {
  const int n = 1024;
  const size_t bytes = (size_t)n * sizeof(float);
  float *h_a = new float[n], *h_b = new float[n], *h_c = new float[n];
  for (int i = 0; i < n; ++i) {
    h_a[i] = (float)i;
    h_b[i] = (float)(2 * i);
  }
  float *d_a, *d_b, *d_c;
  cudaMalloc(&d_a, bytes);
  cudaMalloc(&d_b, bytes);
  cudaMalloc(&d_c, bytes);
  cudaMemcpy(d_a, h_a, bytes, cudaMemcpyHostToDevice);
  cudaMemcpy(d_b, h_b, bytes, cudaMemcpyHostToDevice);
  vecAdd<<<(n + 255) / 256, 256>>>(d_a, d_b, d_c, n);
  cudaDeviceSynchronize();
  cudaMemcpy(h_c, d_c, bytes, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; ++i)
    if (h_c[i] != h_a[i] + h_b[i]) ++bad;
  printf(bad == 0 ? "PASS\n" : "FAIL %d\n", bad);
  cudaFree(d_a);
  cudaFree(d_b);
  cudaFree(d_c);
  delete[] h_a;
  delete[] h_b;
  delete[] h_c;
  return bad == 0 ? 0 : 1;
}
