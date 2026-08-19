#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void vecAdd(float *a, float *b, float *c, int n) {
  int i = ((blockIdx.x * blockDim.x) + threadIdx.x);
  if ((i < n)) {
    c[i] = (a[i] + b[i]);
  }
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
  hipMalloc(&d_a, bytes);
  hipMalloc(&d_b, bytes);
  hipMalloc(&d_c, bytes);
  hipMemcpy(d_a, h_a, bytes, hipMemcpyHostToDevice);
  hipMemcpy(d_b, h_b, bytes, hipMemcpyHostToDevice);
  hipLaunchKernelGGL(vecAdd, dim3(((n + 255) / 256)), dim3(256), 0, 0, d_a, d_b, d_c, n);
  hipDeviceSynchronize();
  hipMemcpy(h_c, d_c, bytes, hipMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; ++i)
    if (h_c[i] != h_a[i] + h_b[i]) ++bad;
  printf(bad == 0 ? "PASS\n" : "FAIL %d\n", bad);
  hipFree(d_a);
  hipFree(d_b);
  hipFree(d_c);
  delete[] h_a;
  delete[] h_b;
  delete[] h_c;
  return bad == 0 ? 0 : 1;
}
