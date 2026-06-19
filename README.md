# cu2hip — formally verified CUDA → HIP transpiler (v1 PoC)

Translates a frozen CUDA subset to portable HIP with a **machine-checked
proof** (`transpile_correct : Qed`, zero admits) that the transpiled
program has identical observable behaviors.

## Quickstart (prerequisites: clang 22, CUDA toolkit, opam/Rocq 9.2, cargo)

```sh
# 1. proofs
eval $(opam env --switch=cuda-rocm-rocq)
make -C rocq vos && make -C rocq
# 2. pipeline
cmake -S frontend -B frontend/build -DCMAKE_BUILD_TYPE=Release
cmake --build frontend/build -j$(nproc)
dune build
cargo build --release --manifest-path cli/Cargo.toml
# 3. transpile + validate
export CU2MINI=$PWD/frontend/build/cu2mini
export MINIMAP=$PWD/_build/default/core/bin/minimap.exe
export HIP_PRINT=$PWD/_build/default/printer/hip_print.exe
./cli/target/release/cu2hip tests/corpus/vectorAdd.cu -o /tmp/v.hip \
  --report /tmp/v.json --validate --shim-dir tests/shim
# 4. full gates
sh tests/run_e2e.sh
```

## Docs (start here)

| File | Contents |
|---|---|
| `SRS.md` | Binding requirements (frozen v1 scope, version pins, acceptance) |
| `docs/SUPPORTED.md` | Accepted subset + API map + reject catalog (MUST match implementation) |
| `docs/ROADMAP.md` | Goal flow G0–G7 with exit criteria |
| `docs/API.md` | Canonical API/CLI/schema registry + change log |
| `docs/VERSIONS.md` | Pinned toolchain + pending verifications |
| `docs/ADMITS.md` | Proof gaps: **zero admits** |
| `docs/EXTEND-perf-asm.md` | v2 hooks (perf + PTX lifter), explicitly unimplemented |
| `rocq/README.md` | Proof architecture + model assumptions |
| `frontend/README.md` | Matcher rules, Clang-shape notes, robustness rules |
| `core/README.md` | Extraction + value-transport bounds |
| `printer/README.md` | Emission rules + known limitations |
| `cli/README.md` | CLI usage, exit codes, report schema |
| `.opencode/skills/api-practices/SKILL.md` | Standing API design/discipline rules |

## Pipeline

```
.cu --[cu2mini, C++/LibTooling]--> MiniCUDA.json --[minimap, EXTRACTED verified core]-->
MiniHIP.json --[hip_print]--> .hip        orchestrated by cu2hip (Rust) with reports
```

- `tests/corpus/` — the proved fragment (must transpile, exit 0)
- `tests/extra/` — transpiles but OUTSIDE the proved fragment (`__shared__`)
- `tests/reject/` — must fail closed, exit 2, one precise diagnostic each
- `tests/expected/` — reviewed frozen outputs (byte-compared by the gate)
- `tests/shim/` — TEST-ONLY CUDA mapping of the v1 HIP surface (host-GPU runs)
- `docker/rocm714/` — ROCm 7.14 `hipcc` CI (needs a docker daemon + AMD GPU for runs)

## Status

G0–G5 + hardening complete; `tests/run_e2e.sh` ALL GREEN; Rocq clean-rebuilt.
Open: G6 container run (`sudo systemctl start docker`, then
`sh docker/rocm714/ci.sh`) and the release tag.
