# ROCm 7.14 hipcc check image (G6).
#
# What it does: compiles the frozen expected HIP outputs
# (tests/expected/*.hip) with hipcc for gfx90a + gfx942 WITHOUT running
# them. Execution happens only where an AMD GPU is present (see ci.sh:
# it runs the binaries iff rocminfo reports a gfx target).
#
# Not rebuilt by developers: `docker build -f docker/rocm714/Dockerfile .`
# after pulling ${ROCM_IMAGE} (default rocm/dev-ubuntu-24.04:7.14.0-full;
# note the '-full' suffix and patch version — bare '7.14' does not exist).
# Record the pulled digest in docs/VERSIONS.md (RepoDigests).

ARG ROCM_IMAGE=rocm/dev-ubuntu-24.04:7.14.0-full
FROM ${ROCM_IMAGE}

SHELL ["/bin/bash", "-c"]
WORKDIR /work

# Expected transpiler outputs under test.
COPY tests/expected/ /work/expected/

# Compile-only check for the two v1 offload targets. -c (no link) keeps
# this a pure frontend check; linking needs the full device runtime.
RUN hipcc -c -std=c++17 --offload-arch=gfx90a --offload-arch=gfx942 \
      -o /tmp/vectorAdd.o /work/expected/vectorAdd.hip \
 && hipcc -c -std=c++17 --offload-arch=gfx90a --offload-arch=gfx942 \
      -o /tmp/saxpy.o /work/expected/saxpy.hip \
 && echo "HIPCC COMPILE CHECK OK (gfx90a,gfx942)"
