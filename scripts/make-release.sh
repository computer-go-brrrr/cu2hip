#!/bin/sh
# make-release.sh — pack a versioned release tarball from built stages:
# dist/cu2hip-<VER>-linux-x86_64.tar.gz (+ .sha256).
# Usage: sh scripts/make-release.sh   (run from repo root; normally via
# `make release`, which builds proofs first)
# Requires: cmake+Clang dev, CUDA toolkit, opam Rocq switch, cargo.
set -e
cd "$(dirname "$0")/.."
# Single source of the release version (per-binary --version literals and
# Cargo.toml must be bumped alongside; see "Versioning" in README.md).
VER="${VER:-$(cat VERSION)}"
DIST="dist/cu2hip-$VER-linux-x86_64"

# All stage builds delegate to the root Makefile (single source of truth),
# release profile for optimized OCaml binaries.
make frontend ocaml cli PROFILE=release

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
