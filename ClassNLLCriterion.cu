#include "utils.h"
#include <stdio.h>
#include <assert.h>

static const int NTHREADS = 32;

__global__ void cunn_ClassNLLCriterion_updateOutput_kernel1(float *output,
                                                           float *total_weight,
                                                           float *input,
                                                           float *target,
                                                           float *weights,
                                                           int size_average,
                                                           int n_classes) {
  assert(threadIdx.x == 0 && threadIdx.y == 0 && threadIdx.z == 0);

  // TODO: T4951791 Reuse code between updateOutput_kernel1 and
  // updateOutput_kernel.

  int t = (int)*target - 1;
  assert(t >= 0 && t < n_classes);
  float cur_weight = weights ? weights[t] : 1.0f;
  *output = -cur_weight * input[t];
  *total_weight = cur_weight;
  if (size_average && *total_weight > 0) {
    *output /= *total_weight;
  }
}

__global__ void cunn_ClassNLLCriterion_updateOutput_kernel(float *output,
                                                           float *total_weight, 
                                                           float *input,
                                                           float *target,
                                                           float *weights,
                                                           int size_average,
                                                           int nframe,
                                                           int ndim,
                                                           int n_classes) {
  __shared__ float shInputs[NTHREADS], acc_weight[NTHREADS];
  int i, t;
  float cur_weight;

  shInputs[threadIdx.x] = 0.0f;
  acc_weight[threadIdx.x] = 0.0f;
  for (i = threadIdx.x; i < nframe; i += NTHREADS) {
      t = target[i] - 1;
      assert(t >= 0 && t < n_classes);
      cur_weight = weights ? weights[t] : 1.0f;
      shInputs[threadIdx.x] -= input[i * ndim + t] * cur_weight;
      acc_weight[threadIdx.x] += cur_weight;
  }
  __syncthreads();

  // TODO: T4951791 Reuse code between updateOutput_kernel1 and
  // updateOutput_kernel
  
  if (threadIdx.x == 0) {
    *output = *total_weight = 0;
    for (i = 0; i < NTHREADS; ++i){
      *output += shInputs[i];
      *total_weight += acc_weight[i];
    }
    if (size_average && *total_weight > 0) {
      *output /= *total_weight;
    }
  }
}

__global__ void cunn_ClassNLLCriterion_updateGradInput_kernel1(
  float* gradInput,
  float* weights,
  float* target,
  float* total_weight,
  int size_average,
  int n_classes)
{
  if (*total_weight <= 0) {
    return;
  }
  float norm = size_average ? (1.0f / *total_weight) : 1.0f;
  int t = (int)*target - 1;
  assert(t >= 0 && t < n_classes);
  gradInput[t] = -(weights ? weights[t] : 1.0f) * norm;
}

__global__ void cunn_ClassNLLCriterion_updateGradInput_kernel(
  float *gradInput,
  float *target,
  float *weights,
  float *total_weight,
  int size_average,
  int nframe,
  int ndim,
  int n_classes)
{
  if (*total_weight <= 0) {
    return;
  }
  int i, t;
  float norm = size_average ? (1.0f / *total_weight) : 1.0f;

  for (i = threadIdx.x; i < nframe; i += NTHREADS) {
    t = (int)target[i] - 1;
    assert(t >= 0 && t < n_classes);
    gradInput[i * ndim + t] = -(weights ? weights[t] : 1.0f) * norm;
  }
}

static int cunn_ClassNLLCriterion_updateOutput(lua_State *L) {
  THCState *state = getCutorchState(L);
  
  THCudaTensor *input =
    (THCudaTensor *)luaT_checkudata(L, 1, "torch.CudaTensor");
  
  THCudaTensor *target =
    (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");

  if (THCudaTensor_nDimension(state, target) > 1) {
    THError("multi-target not supported");
  }
  
  THCudaTensor *weights = NULL;
  if (!lua_isnil(L, 3)) {
    weights = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  }

  int n_dims = THCudaTensor_nDimension(state, input);
  int n_classes = THCudaTensor_size(state, input, n_dims - 1);

  int sizeAverage = lua_toboolean(L, 4);
  
  THCudaTensor *output = 
    (THCudaTensor*)luaT_checkudata(L, 5, "torch.CudaTensor");
  
  THCudaTensor *total_weight = 
    (THCudaTensor*)luaT_checkudata(L, 6, "torch.CudaTensor");

  if (weights) {
    THAssert(THCudaTensor_checkGPU(
      state, 5, input, target, weights, output, total_weight
    ));
  } else {
    THAssert(THCudaTensor_checkGPU(
      state, 4, input, target, output, total_weight
    ));
  }
  

  if (THCudaTensor_nDimension(state, input) > 2) {
    THArgCheck(0, 2, "vector or matrix expected");
  }

  input = THCudaTensor_newContiguous(state, input);
  weights = weights ? THCudaTensor_newContiguous(state, weights) : NULL;
  target = THCudaTensor_newContiguous(state, target);

  float *input_data = THCudaTensor_data(state, input);
  float *weights_data = weights ? THCudaTensor_data(state, weights) : NULL;
  float *target_data = THCudaTensor_data(state, target);
  float *output_data = THCudaTensor_data(state, output);
  float *total_weight_data = THCudaTensor_data(state, total_weight);

  if (THCudaTensor_nDimension(state, input) == 1) {
    cunn_ClassNLLCriterion_updateOutput_kernel1 
      <<<1, 1, 0, THCState_getCurrentStream(state)>>>(
        output_data,
        total_weight_data,
        input_data,
        target_data,
        weights_data,
        sizeAverage,
        n_classes
    );

  } else if (THCudaTensor_nDimension(state, input) == 2) {
    cunn_ClassNLLCriterion_updateOutput_kernel
      <<<1, NTHREADS, 0, THCState_getCurrentStream(state)>>>(
        output_data,
        total_weight_data, 
        input_data,
        target_data,
        weights_data,
        sizeAverage,
        THCudaTensor_size(state, input, 0),
        THCudaTensor_size(state, input, 1),
        n_classes
    );
  }

  cudaError errcode = cudaGetLastError();
  if (errcode != cudaSuccess) {
    THError(cudaGetErrorString(errcode));
  }
  if (weights) {
    THCudaTensor_free(state, weights);
  }
  THCudaTensor_free(state, target);
  THCudaTensor_free(state, input);

  return 0;
}

static int cunn_ClassNLLCriterion_updateGradInput(lua_State *L) {
  THCState *state = getCutorchState(L);

  THCudaTensor *input =
      (THCudaTensor *)luaT_checkudata(L, 1, "torch.CudaTensor");

  THCudaTensor *target = 
    (THCudaTensor*)luaT_checkudata(L, 2, "torch.CudaTensor");

  if (THCudaTensor_nDimension(state, target) > 1) {
    THError("multi-target not supported");
  }
  
  THCudaTensor *weights = NULL;
  if (!lua_isnil(L, 3)) {
    weights = (THCudaTensor *)luaT_checkudata(L, 3, "torch.CudaTensor");
  }
  int n_dims = THCudaTensor_nDimension(state, input);
  int n_classes = THCudaTensor_size(state, input, n_dims - 1);
  
  int sizeAverage = lua_toboolean(L, 4);
  THCudaTensor *total_weight = 
    (THCudaTensor*)luaT_checkudata(L, 5, "torch.CudaTensor");
  THCudaTensor *gradInput = 
    (THCudaTensor *)luaT_checkudata(L, 6, "torch.CudaTensor");
  
  luaL_argcheck(
    L,
    THCudaTensor_isContiguous(state, gradInput),
    6,
    "gradInput must be contiguous"
  );

  if (weights) {
    THAssert(THCudaTensor_checkGPU(
      state, 5, weights, input, target, gradInput, total_weight
    ));
  }
  else {
    THAssert(THCudaTensor_checkGPU(
      state, 4, input, target, gradInput, total_weight
    ));
  }

  if (THCudaTensor_nDimension(state, input) > 2) {
    THArgCheck(0, 2, "vector or matrix expected");
  }

  weights = weights ? THCudaTensor_newContiguous(state, weights) : NULL;
  target = THCudaTensor_newContiguous(state, target);

  float *weights_data = weights ? THCudaTensor_data(state, weights) : NULL;
  float *gradInput_data = THCudaTensor_data(state, gradInput);
  float *target_data = THCudaTensor_data(state, target);
  float *total_weight_data = THCudaTensor_data(state, total_weight);

  if (THCudaTensor_nDimension(state, input) == 1) {
    cunn_ClassNLLCriterion_updateGradInput_kernel1
      <<<1, 1, 0, THCState_getCurrentStream(state)>>>(
        gradInput_data,
        weights_data,
        target_data,
        total_weight_data,
        sizeAverage,
        n_classes
    );
  } else {
    cunn_ClassNLLCriterion_updateGradInput_kernel
      <<<1, NTHREADS, 0, THCState_getCurrentStream(state)>>>(
        gradInput_data,
        target_data,
        weights_data,
        total_weight_data,
        sizeAverage,
        THCudaTensor_size(state, input, 0),
        THCudaTensor_size(state, input, 1),
        n_classes
    );
  }
  cudaError errcode = cudaGetLastError();
  if (errcode != cudaSuccess) {
    THError(cudaGetErrorString(errcode));
  }
  if (weights) {
    THCudaTensor_free(state, weights);
  }
  THCudaTensor_free(state, target);
  
  return 0;
}

static const struct luaL_Reg cunn_ClassNLLCriterion__[] = {
    {"ClassNLLCriterion_updateOutput", cunn_ClassNLLCriterion_updateOutput},
    {"ClassNLLCriterion_updateGradInput",
     cunn_ClassNLLCriterion_updateGradInput},
    {NULL, NULL}};

void cunn_ClassNLLCriterion_init(lua_State *L) {
  luaT_pushmetatable(L, "torch.CudaTensor");
  luaT_registeratname(L, cunn_ClassNLLCriterion__, "nn");
  lua_pop(L, 1);
}
