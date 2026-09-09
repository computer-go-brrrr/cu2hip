# asm-lifter/ — v2 inline-PTX lifter (TODO, unimplemented in v1)

See `docs/EXTEND-perf-asm.md`. Replaces `Unsupported[inline-asm]` sites
with portable HIP subprograms (pattern table for ~25 common PTX ops +
special-reg mapping), failing closed outside the table. Its output must
satisfy `WellFormedCuda`-style checks; extending `transpile_correct` to
lifted fragments is future research work. No code here yet by design.
