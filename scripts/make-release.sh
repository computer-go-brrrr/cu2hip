#!/bin/sh
# make-release.sh — build all four stage binaries from scratch and pack a
# versioned tarball: dist/cu2hip-<VER>-linux-x86_64.tar.gz (+ .sha256).
# Usage: sh scripts/make-release.sh   (run from repo root)
# Requires: cmake+Clang dev, CUDA toolkit, opam Rocq switch, cargo.
# Rocq proofs are NOT rebuilt here (CI covers them); dune consumes the
# extraction outputs already present under core/lib/extracted/.
set -e
cd "$(dirname "$0")/.."
VER="${VER:-0.1.0}"
DIST="dist/cu2hip-$VER-linux-x86_64"

cmake -S frontend -B frontend/build -DCMAKE_BUILD_TYPE=Release
cmake --build frontend/build -j"$(nproc)"

eval "$(opam env --switch=cuda-rocm-rocq 2>/dev/null)"
# NOTE: bare `dune build` only builds the cwd alias (empty at root);
# @all is required to recurse into core/ and printer/.
dune build --release @all

cargo build --release --manifest-path cli/Cargo.toml

rm -rf "$DIST"
mkdir -p "$DIST/bin"
cp frontend/build/cu2mini "$DIST/bin/"
cp _build/default/core/bin/minimap.exe "$DIST/bin/minimap"
cp _build/default/printer/hip_print.exe "$DIST/bin/hip_print"
cp cli/target/release/cu2hip "$DIST/bin/"
strip "$DIST"/bin/* 2>/dev/null || true
cp README.md LICENSE "$DIST/"

# Smoke test: every binary reports its version.
"$DIST/bin/cu2mini" --version
"$DIST/bin/minimap" --version
"$DIST/bin/hip_print" --version
"$DIST/bin/cu2hip" --version

mkdir -p dist
tar -czf "$DIST.tar.gz" -C dist "$(basename "$DIST")"
(cd dist && sha256sum "$(basename "$DIST").tar.gz" > "$(basename "$DIST").sha256")
cat "dist/$(basename "$DIST").sha256"
echo "RELEASE OK: dist/$(basename "$DIST").tar.gz"
