# saxpy — behavior note

- Computes `y[i] = alpha * x[i] + y[i]` for `n = 2048`, `alpha = 2.5f`.
  Prints `PASS`, exits 0 on success.
- Launch: 8 blocks × 256 threads, 1-D. Scalar `alpha` passed by value.
- `WellSync` argument: each thread performs a read-modify-write on exactly one
  distinct global index; no sharing between threads; device sync before D2H.
  Race-free by disjointness. FP note: single op order per element, so the
  validator compares float-exact with a small tolerance report (see SRS §5).
- Expected HIP output: API prefix swap per `docs/SUPPORTED.md`; kernel body unchanged.
