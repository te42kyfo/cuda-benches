#include "../MeasurementSeries.hpp"
#include "../dtime.hpp"
#include "../gpu-error.h"
#include "../gpu_clock.cuh"
#include "../metrics.cuh"
#include <iomanip>
#include <iostream>
#include <map>
#include <nvml.h>

using namespace std;

template <typename T> __global__ void initKernel(T *A, size_t N) {
  size_t tidx = blockDim.x * blockIdx.x + threadIdx.x;
  for (int idx = tidx; idx < N; idx += blockDim.x * gridDim.x) {
    A[idx] = 1.1;
  }
}

template <typename T, int N, int M>
__global__ void FMA_mixed(T p, T *A, int iters) {
#pragma unroll(1)
  for (int iter = 0; iter < iters; iter++) {
    T t[M];
#pragma unroll
    for (int m = 0; m < M; m++) {
      t[m] = p + threadIdx.x + iter + m;
    }
#pragma unroll
    for (int n = 0; n < N / M; n++) {
#pragma unroll
      for (int m = 0; m < M; m++) {
        t[m] = t[m] * (T)0.9 + (T)0.5;
      }
    }
#pragma unroll
    for (int m = 0; m < M; m++) {
      if (t[m] > (T)22313.0) {
        A[0] = t[m];
      }
    }
  }
}

template <typename T, int N, int M>
__global__ void FMA_separated(T p, T *A, int iters) {

  for (int iter = 0; iter < iters; iter++) {
#pragma unroll
    for (int m = 0; m < M; m++) {
      T t = p + threadIdx.x + iter + m;
      for (int n = 0; n < N; n++) {
        t = t * (T)0.9 + (T)0.5;
      }
      if (t > (T)22313.0) {
        A[0] = t;
      }
    }
  }
}

template <typename T, int N, int M>
__global__ void DIV_separated(T p, T *A, int iters) {

#pragma unroll(1)
  for (int iter = 0; iter < iters; iter++) {
    for (int m = 0; m < M; m++) {
      T t = p + threadIdx.x + iter + m;

      for (int n = 0; n < N; n++) {
        t = 0.1 / (t + 0.2);
      }

      A[threadIdx.x + iter] = t;
    }
  }
}

template <typename T, int N, int M>
__global__ void SQRT_separated(T p, T *A, int iters) {

#pragma unroll(1)
  for (int iter = 0; iter < iters; iter++) {

    for (int m = 0; m < M; m++) {
      T t = p + threadIdx.x + iter + m;

      for (int n = 0; n < N; n++) {
        t = sqrt(t + 0.2);
      }

      A[threadIdx.x + iter] = t;
    }
  }
}

template <typename T, int N, int M>
double measure(int warpCount, void (*kernel)(T, T *, int)) {
  nvmlDevice_t device;
  nvmlDeviceGetHandleByIndex(0, &device);
  unsigned int clock = 0;

  const int iters = 10000;
  const int blockSize = 32 * warpCount;
  const int blockCount = 1;

  MeasurementSeries time;

  T *dA;
  GPU_ERROR(cudaMalloc(&dA, iters * 2 * sizeof(T)));
  initKernel<<<52, 256>>>(dA, iters * 2);
  GPU_ERROR(cudaDeviceSynchronize());

  kernel<<<blockCount, blockSize>>>((T)0.32, dA, iters);
  nvmlDeviceGetClockInfo(device, NVML_CLOCK_SM, &clock);
  GPU_ERROR(cudaDeviceSynchronize());
  for (int i = 0; i < 1; i++) {
    double t1 = dtime();
    kernel<<<blockCount, blockSize>>>((T)0.32, dA, iters);
    GPU_ERROR(cudaDeviceSynchronize());
    double t2 = dtime();
    time.add(t2 - t1);
  }
  cudaFree(dA);

  double rcpThru = time.value() * clock * 1e6 / N / iters / warpCount;
  cout << setprecision(1) << fixed << typeid(T).name() << " " << setw(5) << N
       << " " << warpCount << " " << setw(5) << M << " "
       << " " << setw(5) << time.value() * 100 << " " << setw(5)
       << time.spread() * 100 << "%   " << setw(5) << setprecision(2) << rcpThru
       << "\n";
  return rcpThru;
}

template <typename T> void measureTabular(int maxWarpCount) {

  vector<map<pair<int, int>, double>> r(3);
  const int N = 128;
  for (int warpCount = 1; warpCount <= maxWarpCount; warpCount *= 2) {
    r[0][{warpCount, 1}] = measure<T, N, 1>(warpCount, FMA_mixed<T, N, 1>);
    r[1][{warpCount, 1}] = measure<T, N, 1>(warpCount, DIV_separated<T, N, 1>);
    r[2][{warpCount, 1}] = measure<T, N, 1>(warpCount, SQRT_separated<T, N, 1>);
    r[0][{warpCount, 2}] = measure<T, N, 2>(warpCount, FMA_mixed<T, N, 2>);
    r[1][{warpCount, 2}] = measure<T, N, 2>(warpCount, DIV_separated<T, N, 2>);
    r[2][{warpCount, 2}] = measure<T, N, 2>(warpCount, SQRT_separated<T, N, 2>);
    r[0][{warpCount, 3}] = measure<T, N, 3>(warpCount, FMA_mixed<T, N, 3>);
    r[1][{warpCount, 3}] = measure<T, N, 3>(warpCount, DIV_separated<T, N, 3>);
    r[2][{warpCount, 3}] = measure<T, N, 3>(warpCount, SQRT_separated<T, N, 3>);
    r[0][{warpCount, 4}] = measure<T, N, 4>(warpCount, FMA_mixed<T, N, 4>);
    r[1][{warpCount, 4}] = measure<T, N, 4>(warpCount, DIV_separated<T, N, 4>);
    r[2][{warpCount, 4}] = measure<T, N, 4>(warpCount, SQRT_separated<T, N, 4>);
    r[0][{warpCount, 5}] = measure<T, N, 5>(warpCount, FMA_mixed<T, N, 5>);
    r[1][{warpCount, 5}] = measure<T, N, 5>(warpCount, DIV_separated<T, N, 5>);
    r[2][{warpCount, 5}] = measure<T, N, 5>(warpCount, SQRT_separated<T, N, 5>);
    r[0][{warpCount, 6}] = measure<T, N, 6>(warpCount, FMA_mixed<T, N, 6>);
    r[1][{warpCount, 6}] = measure<T, N, 6>(warpCount, DIV_separated<T, N, 6>);
    r[2][{warpCount, 6}] = measure<T, N, 6>(warpCount, SQRT_separated<T, N, 6>);
    r[0][{warpCount, 7}] = measure<T, N, 7>(warpCount, FMA_mixed<T, N, 7>);
    r[1][{warpCount, 7}] = measure<T, N, 7>(warpCount, DIV_separated<T, N, 7>);
    r[2][{warpCount, 7}] = measure<T, N, 7>(warpCount, SQRT_separated<T, N, 7>);
    r[0][{warpCount, 8}] = measure<T, N, 8>(warpCount, FMA_mixed<T, N, 8>);
    r[1][{warpCount, 8}] = measure<T, N, 8>(warpCount, DIV_separated<T, N, 8>);
    r[2][{warpCount, 8}] = measure<T, N, 8>(warpCount, SQRT_separated<T, N, 8>);
    cout << "\n";
  }

  for (int i = 0; i < 3; i++) {
    for (int warpCount = 1; warpCount <= maxWarpCount; warpCount *= 2) {
      for (int streams = 1; streams <= 8; streams++) {
        cout << setw(6) << setprecision(2) << r[i][{warpCount, streams}] << " ";
      }
      cout << "\n";
    }
    cout << "\n";
  }
}

int main(int argc, char **argv) {
  nvmlInit();

  measureTabular<double>(32);
}
