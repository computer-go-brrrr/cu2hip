(* Extract.v — extraction of the verified core to OCaml (G4).
   Emits core/extracted/*.ml(.mli). Value mapping notes (see core/README.md):
   - Z -> OCaml int (ExtrOcamlZInt, 63-bit; driver only TRANSPORTS literals,
     never computes on them; frontend emits 32-bit-range literals only).
   - String -> OCaml string; PrimFloat.float -> OCaml float (binary64).
   The proof (Sim.vo) is about the Gallina model; extraction is trusted
   per the CompCert-style TCB (Rocq extractor + OCaml compiler). Rocq 9.2. *)

From Stdlib Require Import ExtrOcamlBasic ExtrOcamlString ExtrOcamlZInt ExtrOCamlFloats.
Require Import Cu2Hip.Map.

Cd "../core/lib/extracted".
Separate Extraction
  Map.map_program Map.mapApi
  Map.map_expr Map.map_stmts Map.map_stmt Map.map_kernel Map.map_hostNode Map.map_host.
