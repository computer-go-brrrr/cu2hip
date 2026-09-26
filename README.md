# cu2hip — formally verified CUDA → HIP transpiler (v1 PoC)

Translates a frozen CUDA subset to portable HIP with a **machine-checked
proof** (`transpile_correct : Qed`, zero admits) that the transpiled
program has identical observable behaviors.

## Quickstart (prerequisites: clang 22, CUDA toolkit, opam/Rocq 9.2, cargo)

```sh
eval $(opam env --switch=cuda-rocm-rocq)
make proofs frontend ocaml cli   # ~10 min first time (Rocq); see `make help`
make check                        # fixtures + E2E + batches, no GPU needed
make validate                     # GPU differential, skips without NVIDIA GPU
make release                      # versioned dist tarball (implies proofs)
```
```

## Usage

```sh
# Single file (needs only the built binaries + a CUDA toolkit for parsing):
./cli/target/release/cu2hip your_file.cu -o your_file.hip --report report.json
# Exit 0: .hip written. Exit 2: input outside the v1 subset — the report
# names the exact feature and location (see docs/SUPPORTED.md).
# --validate additionally compiles both sides with nvcc and compares GPU runs.
# --arch/--cuda-path/--resource-dir override the sm_86, /opt/cuda,
# /usr/lib/clang/22 defaults. `cu2hip --batch <dir> --expect-exit N` runs a
# whole directory with per-file expectations.
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
| `docs/MATH.md` | Mathematics of the Rocq verification, definition by definition |
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

G0–G7 complete; `tests/run_e2e.sh` ALL GREEN; Rocq clean-rebuilt with zero
admits; `hipcc` compile-check green in ROCm 7.14 CI; `v0.1.0` tagged with a
`dist/` release tarball recipe (`make release`; `VERSION` file pins it).
Open: GPU execution of `ci.sh` (needs AMD hardware) and the v2 hooks in
`docs/EXTEND-perf-asm.md` (perf autotuning, PTX lifter, Lean mirror).
