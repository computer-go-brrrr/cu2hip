(* MiniHip.v — HIP side: instantiates MiniCuda's shared AST/semantics.
   Shapes mirror minicuda/v1 exactly (see minihip-v1.schema.json);
   only the header and API-name set differ. Rocq 9.2. *)

From Stdlib Require Import List String.
Require Import Cu2Hip.MiniCuda.
Import ListNotations.
Open Scope string_scope.

Definition hip_header : string := "hip/hip_runtime.h".
Definition cuda_header : string := "cuda_runtime.h".

Definition cuda_apis : list string :=
  ["cudaMalloc"; "cudaMemcpy"; "cudaMemset"; "cudaFree";
   "cudaStreamCreate"; "cudaStreamSynchronize"; "cudaStreamDestroy";
   "cudaEventCreate"; "cudaEventRecord"; "cudaEventSynchronize"; "cudaEventDestroy";
   "cudaEventElapsedTime"; "cudaGetLastError"; "cudaGetErrorString";
   "cudaSetDevice"; "cudaDeviceSynchronize"].

Definition hip_apis : list string :=
  ["hipMalloc"; "hipMemcpy"; "hipMemset"; "hipFree";
   "hipStreamCreate"; "hipStreamSynchronize"; "hipStreamDestroy";
   "hipEventCreate"; "hipEventRecord"; "hipEventSynchronize"; "hipEventDestroy";
   "hipEventElapsedTime"; "hipGetLastError"; "hipGetErrorString";
   "hipSetDevice"; "hipDeviceSynchronize"].

Definition WellFormedCuda (p : program) : Prop :=
  wf_program cuda_apis cuda_header p.

Definition WellFormedHip (p : program) : Prop :=
  wf_program hip_apis hip_header p.
