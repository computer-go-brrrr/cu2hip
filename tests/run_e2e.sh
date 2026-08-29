#!/bin/sh
# run_e2e.sh — G4 regression gate (stdlib tools only; Rust runner lands at G5).
# Rebuilds nothing; runs the frozen pipeline and diffs against expectations.
# Usage: sh tests/run_e2e.sh
# Exit 0 iff: fixtures valid, both kernels flow cu2mini->minimap->hip_print
#   with outputs byte-identical to tests/expected/*.hip, and all four
#   reject probes exit 2 with exactly their documented diagnostic.
set -e
cd "$(dirname "$0")/.."
CU2MINI=frontend/build/cu2mini
eval "$(opam env --switch=cuda-rocm-rocq 2>/dev/null)"
MM=_build/default/core/bin/minimap.exe
HP=_build/default/printer/hip_print.exe
python3 tests/check_fixtures.py
for k in vectorAdd saxpy; do
  $CU2MINI tests/corpus/$k.cu -o /tmp/e2e.$k.cu.json
  $MM /tmp/e2e.$k.cu.json -o /tmp/e2e.$k.hip.json
  $HP /tmp/e2e.$k.hip.json -o /tmp/e2e.$k.hip
  cmp /tmp/e2e.$k.hip tests/expected/$k.hip
  echo "E2E OK: $k"
done
# Extra: __shared__ pipeline path (outside the proved fragment, see
# tests/extra/reduce-shared.expected.md).
$CU2MINI tests/extra/reduce-shared.cu -o /tmp/e2e.rs.cu.json
$MM /tmp/e2e.rs.cu.json -o /tmp/e2e.rs.hip.json
$HP /tmp/e2e.rs.hip.json -o /tmp/e2e.rs.hip
cmp /tmp/e2e.rs.hip tests/expected/reduce-shared.hip
echo "E2E OK: reduce-shared (extra)"
check_reject() { # file feature
  if $CU2MINI tests/reject/$1.cu -o /tmp/e2e.$1.json 2>/dev/null; then
    echo "REJECT FAIL (exit 0): $1"; exit 1
  fi
  feat=$(python3 -c "import json;print([d['feature'] for d in json.load(open('/tmp/e2e.$1.json'))['diagnostics']])")
  [ "$feat" = "['$2']" ] || { echo "REJECT FAIL ($1): $feat"; exit 1; }
  echo "REJECT OK: $1 -> $2"
}
check_reject asm inline-asm
check_reject device-fn device-functions
check_reject warp warp-collective
check_reject loop loops
check_reject cuda-header unsupported-include
echo "ALL E2E GREEN"
