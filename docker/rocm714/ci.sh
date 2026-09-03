#!/bin/sh
# ci.sh — G6 ROCm CI entrypoint (run on a machine with docker access).
# 1. Pulls ${ROCM_IMAGE} and prints its digest (record in docs/VERSIONS.md).
# 2. Builds docker/rocm714/Dockerfile (hipcc compile check, gfx90a+gfx942).
# 3. If an AMD GPU is visible in the container (rocminfo reports gfx*),
#    links + runs the expected binaries and checks for PASS.
# Exit 0 iff every executed stage passes; GPU execution is skipped
# (not failed) where no AMD GPU is present.
set -e
cd "$(dirname "$0")/../.."
ROCM_IMAGE="${ROCM_IMAGE:-rocm/dev-ubuntu-24.04:7.14.0-full}"

docker pull "$ROCM_IMAGE"
echo "--- image digests (record RepoDigest in docs/VERSIONS.md) ---"
docker inspect --format '{{.RepoDigests}}' "$ROCM_IMAGE"

docker build -f docker/rocm714/Dockerfile \
  --build-arg "ROCM_IMAGE=$ROCM_IMAGE" -t cu2hip-hipcc-check .
echo "HIPCC COMPILE CHECK OK"

if docker run --rm --device=/dev/kfd --device=/dev/dri \
    "$ROCM_IMAGE" rocminfo 2>/dev/null | grep -q "Name:.*gfx"; then
  echo "--- AMD GPU detected: linking + running expected binaries ---"
  docker run --rm --device=/dev/kfd --device=/dev/dri \
    -v "$PWD/tests/expected:/work/expected:ro" "$ROCM_IMAGE" \
    bash -c 'for k in vectorAdd saxpy; do
      hipcc -O2 -std=c++17 --offload-arch=gfx90a --offload-arch=gfx942 \
        -o /tmp/$k /work/expected/$k.hip \
      && /tmp/$k || exit 1;
    done && echo "GPU EXECUTION OK (PASS/PASS)"'
# NOTE: execution targets CDNA (gfx90a MI200, gfx942 MI300); RDNA coverage
# is a v1.1 item (see docs/ROADMAP.md non-goals).
else
  echo "No AMD GPU visible: execution skipped (compile check stands)."
fi
