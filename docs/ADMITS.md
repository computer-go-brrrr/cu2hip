# ADMITS — tracked proof gaps (G7 acceptance input)

Rule (SRS section 5 VR-2): at most 2 named `Admitted` lemmas, each with a
close-out plan. Current status: **zero admits**.

- 2026-09-20: `transpile_correct` closes with `Qed`. `Print Assumptions`
  reports only `PrimFloat.*` kernel primitives (IEEE-754 implementation
  TCB, same category as CompCert's trusted arithmetic) — no admits, no
  classic axioms (no functional extensionality, no excluded middle).

Model limitations that are DOCUMENTED (not admits) live in
`rocq/README.md` under "Model assumptions" and in `Sim.v`'s header:
WellSync-v1 scope, global-disjointness assumption, host_code opacity,
index-cast elision, dim3 unwrapping.
