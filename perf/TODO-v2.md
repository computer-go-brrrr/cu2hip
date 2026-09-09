# perf/ — v2 performance stage (TODO, unimplemented in v1)

See `docs/EXTEND-perf-asm.md` for the binding design constraint: this stage
sits AFTER the frozen verified core (`minimap`) and transforms
`MiniHIP.json` without touching `Map.map_program`. Each transform needs
its own preservation argument (differential runs minimum, `alive-tv`
refinement where feasible). No code here yet by design.
