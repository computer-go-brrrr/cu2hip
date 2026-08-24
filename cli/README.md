# cli/ — `cu2hip` orchestrating CLI + validator (G5)

Drives the frozen pipeline per file: `cu2mini` → `minimap` (extracted
verified core) → `hip_print`. Unverified shell; the only trusted
component in the path is `minimap`'s `Map.map_program`.

## Build

```sh
cargo build --release      # binary at cli/target/release/cu2hip
```

Deps: `clap` (derive), `serde`, `serde_json` (see `Cargo.lock`).

## Usage

```sh
# Single file (SRS CLI contract)
cu2hip [--arch sm_86] in.cu -o out.hip --report report.json [--validate]

# Batch with per-file expectations (parallel via std threads)
cu2hip --batch tests/corpus --output out/ --report reports/ --expect-exit 0
cu2hip --batch tests/reject --output out/ --report reports/ --expect-exit 2
```

Stage discovery: `--cu2mini/--minimap/--hip-print` flags, else
`$CU2MINI/$MINIMAP/$HIP_PRINT`, else `PATH`.

`--validate` (single mode): compiles the original `.cu` with `nvcc` and the
transpiled `.hip` through `--shim-dir` (default `tests/shim`), runs both on
the host GPU, compares stdout + exit codes. This checks emitted bodies and
glue; real `hipcc`/AMD-GPU checking lands at G6.

## Exit codes

`0` ok (validation match/skipped) · `1` validation mismatch or batch
expectation failure · `2` fail-closed reject (diagnostics in report, no
`.hip`) · `3` internal error (bad CLI, missing stage, IO).

## Report schema (`cu2hip-report/v1`)

`{version, input, output, arch, stages: [{name, exit, ms}],
diagnostics: [{code, feature, loc, hint}], validation: null |
{status: match|mismatch|skipped, cuda_stdout, hip_stdout, cuda_exit,
hip_exit, note}}`.
