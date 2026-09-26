# VERSIONS — Pinned Toolchain (G0 record, 2026-09-20)

## Host (observed, CachyOS, 12 CPUs, NVIDIA RTX 3050 Laptop GPU)

| Tool | Version | Role |
|---|---|---|
| `clang` | 22.1.8 | frontend base; 12.9-subset verified (warns benignly on newer toolkits) |
| `nvcc` | release 13.4, V13.4.59 | host oracle for differential runs (NOT the input ceiling) |
| `cargo` / `rustc` | 1.98.1 | CLI + validator |
| `cmake` | 4.4.3 | frontend build |
| `python3` | 3.14.7 (no pip module) | scripts only; stdlib or vendored deps |
| `opam` | 2.5.1, switch `cuda-rocm-rocq` (OCaml 5.3.0, built; Rocq 9.2 installed, smoke `Qed` green) | Rocq proofs |
| `docker` | 29.8.0 | ROCm CI |
| `git` | 2.55.0 | VCS |
| GPU | NVIDIA RTX 3050 Laptop (nvidia-smi OK) | host differential runs |
| AMD GPU | none (`/dev/kfd` absent, no `rocminfo`) | ROCm execution via CI/GPU runner only |

## Frozen pins (binding, per SRS §8)

| Item | Pin |
|---|---|
| CUDA input language | 12.9.x (13.x-only → `Unsupported`) |
| ROCm CI | 7.14.0 (`rocm/dev-ubuntu-24.04:7.14.0-full`, digest `sha256:439edaa8f0c4be4a3728e528f87b8a2ea1f051f34cf10b27caa4bd94f562eda7`, pulled 2026-09-20) |
| HIPIFY reference | 18.x, `amd-develop` (oracle only) |
| Rocq | 9.2.0, Platform 2026.07.0, OCaml 5.3.0 (4.14.1 rejected: fails to build under system GCC 16, `caml_prim_table` error; Rocq 9.2 supports OCaml 5.x) |
| JSON schema | `Mini*.json` v1 (defined at G1) |

## Pending verification (G0 exit)

- [x] `cuda-rocm-rocq` opam switch completes; `rocq-prover rocq-core=9.2.0` installs (smoke `Qed` compiles, 2026-09-20)
- [x] ROCm 7.14 image pull + digest recorded (2026-09-20; `RepoDigest: rocm/dev-ubuntu-24.04@sha256:439edaa8...`; note the `-full` suffix + patch version are required — bare `7.14` does not exist)
- [x] `clang` 22.1.8 accepted for CUDA headers (compiles 12.9-subset corpus for sm_86; warns 13.4 > latest partially supported 12.9 — benign, confirms 12.9 input ceiling)
