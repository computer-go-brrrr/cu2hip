#include <cuda_runtime.h>
#include <cstdio>

__global__ void saxpy(float alpha, const float *x, float *y, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) y[i] = alpha * x[i] + y[i];
}

int main() {
  const int n = 2048;
  const float alpha = 2.5f;
  const size_t bytes = (size_t)n * sizeof(float);
  float *h_x = new float[n], *h_y = new float[n], *h_ref = new float[n];
  for (int i = 0; i < n; ++i) {
    h_x[i] = (float)i * 0.5f;
    h_y[i] = (float)i * 1.5f;
    h_ref[i] = alpha * h_x[i] + h_y[i];
  }
  float *d_x, *d_y;
  cudaMalloc(&d_x, bytes);
  cudaMalloc(&d_y, bytes);
  cudaMemcpy(d_x, h_x, bytes, cudaMemcpyHostToDevice);
  cudaMemcpy(d_y, h_y, bytes, cudaMemcpyHostToDevice);
  saxpy<<<(n + 255) / 256, 256>>>(alpha, d_x, d_y, n);
  cudaDeviceSynchronize();
  float *h_out = new float[n];
  cudaMemcpy(h_out, d_y, bytes, cudaMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; ++i)
    if (h_out[i] != h_ref[i]) ++bad;
  printf(bad == 0 ? "PASS\n" : "FAIL %d\n", bad);
  cudaFree(d_x);
  cudaFree(d_y);
  delete[] h_x;
  delete[] h_y;
  delete[] h_ref;
  delete[] h_out;
  return bad == 0 ? 0 : 1;
}
