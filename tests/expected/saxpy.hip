#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void saxpy(float alpha, float *x, float *y, int n) {
  int i = ((blockIdx.x * blockDim.x) + threadIdx.x);
  if ((i < n)) {
    y[i] = ((alpha * x[i]) + y[i]);
  }
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
  hipMalloc(&d_x, bytes);
  hipMalloc(&d_y, bytes);
  hipMemcpy(d_x, h_x, bytes, hipMemcpyHostToDevice);
  hipMemcpy(d_y, h_y, bytes, hipMemcpyHostToDevice);
  hipLaunchKernelGGL(saxpy, dim3(((n + 255) / 256)), dim3(256), 0, 0, alpha, d_x, d_y, n);
  hipDeviceSynchronize();
  float *h_out = new float[n];
  hipMemcpy(h_out, d_y, bytes, hipMemcpyDeviceToHost);
  int bad = 0;
  for (int i = 0; i < n; ++i)
    if (h_out[i] != h_ref[i]) ++bad;
  printf(bad == 0 ? "PASS\n" : "FAIL %d\n", bad);
  hipFree(d_x);
  hipFree(d_y);
  delete[] h_x;
  delete[] h_y;
  delete[] h_ref;
  delete[] h_out;
  return bad == 0 ? 0 : 1;
}
