# cu2hip root Makefile — single source of truth for all builds.
# README.md, .github/workflows/ci.yml, and scripts/make-release.sh all
# delegate here; never duplicate build commands elsewhere.
#
# Prerequisites: cmake + Clang 22 dev, CUDA toolkit, opam switch
#   `cuda-rocm-rocq` (OCaml 5.3.0 + Rocq 9.2.0), cargo, python3.
#   Run `eval $(opam env --switch=cuda-rocm-rocq)` first (each recipe
#   re-evals it where needed so plain `make <target>` works).
#
# Tunables (env or command line):
#   ARCH=sm_86               GPU arch forwarded to cu2mini
#   CUDA_PATH=/opt/cuda      CUDA toolkit forwarded to cu2mini
#   RESOURCE_DIR=...         Clang resource dir (distro layout differs)
#   CMAKE_EXTRA=...          extra -D flags for the frontend configure
# Standard stage-binary env (also honored directly by run_e2e.sh/cu2hip):
#   CU2MINI, MINIMAP, HIP_PRINT

SWITCH := cuda-rocm-rocq
ARCH ?= sm_86
CUDA_PATH ?= /opt/cuda
RESOURCE_DIR ?= /usr/lib/clang/22
BUILD_JOBS ?= $(shell nproc 2>/dev/null || echo 4)
# Dune profile: dev for iteration, release for `make release`.
PROFILE ?= dev

export CU2MINI := $(CURDIR)/frontend/build/cu2mini
export MINIMAP := $(CURDIR)/_build/default/core/bin/minimap.exe
export HIP_PRINT := $(CURDIR)/_build/default/printer/hip_print.exe

.PHONY: help proofs frontend ocaml cli check validate release clean distclean

help:
	@echo "targets: proofs frontend ocaml cli | check | validate | release | clean distclean"
	@echo "flow:    make proofs frontend ocaml cli && make check   (no GPU needed)"
	@echo "         make validate   # needs nvcc + NVIDIA GPU, skips otherwise"
	@echo "         make release    # versioned dist tarball (implies proofs)"

proofs:
	eval $$(opam env --switch=$(SWITCH) 2>/dev/null); \
	cd rocq && (test -f Makefile || rocq makefile -f _RocqProject -o Makefile) && \
	mkdir -p ../core/lib/extracted && make vos && make

frontend:
	cmake -S frontend -B frontend/build -DCMAKE_BUILD_TYPE=Release $(CMAKE_EXTRA)
	cmake --build frontend/build -j$(BUILD_JOBS)

ocaml:
	eval $$(opam env --switch=$(SWITCH) 2>/dev/null); \
	dune build --profile $(PROFILE) @all

cli:
	cargo build --release --manifest-path cli/Cargo.toml

check:
	python3 tests/check_fixtures.py
	ARCH=$(ARCH) sh tests/run_e2e.sh
	./cli/target/release/cu2hip --batch tests/corpus \
	  --output /tmp/cu2hip-batch-h --report /tmp/cu2hip-batch-r --expect-exit 0 \
	  --arch $(ARCH) --cuda-path $(CUDA_PATH) --resource-dir $(RESOURCE_DIR)
	./cli/target/release/cu2hip --batch tests/reject \
	  --output /tmp/cu2hip-batch-rj --report /tmp/cu2hip-batch-rjr --expect-exit 2 \
	  --arch $(ARCH) --cuda-path $(CUDA_PATH) --resource-dir $(RESOURCE_DIR)

validate:
	command -v nvcc >/dev/null && nvidia-smi -L >/dev/null 2>&1 || \
	  { echo "validate: no NVIDIA GPU toolchain; skipping"; exit 0; }; \
	for k in vectorAdd saxpy; do \
	  ./cli/target/release/cu2hip tests/corpus/$$k.cu -o /tmp/cu2hip-$$k.hip \
	    --report /tmp/cu2hip-$$k.json --validate --shim-dir tests/shim \
	    --arch $(ARCH) --cuda-path $(CUDA_PATH) --resource-dir $(RESOURCE_DIR) || exit 1; \
	done
	cmp /tmp/cu2hip-vectorAdd.hip tests/expected/vectorAdd.hip
	cmp /tmp/cu2hip-saxpy.hip tests/expected/saxpy.hip
	@echo "VALIDATE OK (GPU differential match)"

release: proofs
	sh scripts/make-release.sh

clean:
	rm -rf frontend/build _build cli/target dist

distclean: clean
	rm -f rocq/Makefile rocq/Makefile.conf rocq/.Makefile.d rocq/*.vo rocq/*.vos \
	  rocq/*.vok rocq/*.glob core/lib/extracted/*.ml core/lib/extracted/*.mli
