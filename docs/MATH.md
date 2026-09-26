# Mathematics of the Rocq Verification (`rocq/`)

Reference for the v1 machine-checked proof. Every definition, lemma, and
theorem below is quoted from (or directly paraphrases) the sources
`MiniCuda.v`, `MiniHip.v`, `Map.v`, `Sim.v` as built by
`make -C rocq` under Rocq 9.2. Status: `transpile_correct : Qed`,
zero `Admitted`, zero classic axioms
(`Print Assumptions` reports only `PrimFloat.*` kernel primitives).

## 1. Logical framework

Work is in Rocq's Calculus of Inductive Constructions. Two disciplines
govern the development:

- **Deep embedding.** MiniCUDA/MiniHIP programs are data: Gallina
  inductives (`expr`, `stmt`, `kernel`, `hostNode`, `program`). All
  reasoning is about these syntax trees, never about CUDA source text.
- **Decidable checks vs propositions.** Well-formedness is computed by
  boolean functions (`wf_expr`, `wf_kernel`, `wf_hostNode`,
  `wf_launch_targets`); the theorem hypothesis `wf_program` lifts them
  into `Prop` with `/\`. Partiality (stuck executions) is modeled by the
  `option` monad: `None` means "no behavior", and behavior equality
  includes agreement on stuckness.
- **Structural recursion only.** Every fixpoint terminates by construction
  on a `{struct}` argument; there is no fuel, no well-foundedness
  argument, and no partial function. Where Coq's guard checker rejects
  mutual recursion through nested lists, definitions use the nested-`fix`
  pattern of §12.

## 2. Syntax

```
scalarTy  ::= TyInt | TyFloat | TyDouble
binop     ::= BAdd | BSub | BMul | BDiv | BMod
            | BLt | BLe | BGt | BGe | BEq | BNe | BAnd | BOr
unop      ::= UNeg | UNot
builtin   ::= B_tidx | B_tidy | B_tidz          (threadIdx.*)
            | B_bidx | B_bidy | B_bidz          (blockIdx.*)
            | B_bdimx | B_bdimy | B_bdimz        (blockDim.*)
            | B_gdimx | B_gdimy | B_gdimz        (gridDim.*)
expr      ::= EVar(x) | EInt(z:Z) | EFloat(f:PrimFloat.float)
            | EBinop(op,l,r) | EUnop(op,e)
            | ESubscript(base,idx) | EBuiltin(b)
            | EAddrof(x) | ECall(f,args)
stmt      ::= SLet(x,ty,e) | SStore(tgt,v) | SIf(c,th,el) | SSync | SExpr(e)
param     ::= { pname; pty; pptr }
sharedDecl::= { sname; sty; ssize:Z }
kernel    ::= { kname; kparams; kshared; kbody }
copyKind  ::= CK_H2D | CK_D2H | CK_D2D | CK_H2H
hostNode  ::= HApi(f,args,ck) | HLaunch(k,grid,block,stream,args)
            | HHostCode(text,loc)
program   ::= { pheader; pkernels; phost }
diagnostic::= Diag(code,feature,loc,hint)
envelope  ::= { esource; eprogram:option program; ediags }
```

`MiniHip.v` reuses this AST verbatim and contributes only the name sets
(`cuda_apis`, `hip_apis`: 16 names each) and headers
(`cuda_runtime.h`, `hip/hip_runtime.h`), plus
`WellFormedCuda/Hip := wf_program <apis> <header>`.

## 3. Semantic domains

```
val  ::= VInt(z:Z) | VFloat(f:PrimFloat.float) | VPtr(arr:string) | VUnit
gmem := string -> Z -> val        (device arrays; total, default VInt 0)
hmem := string -> Z -> val        (host arrays; total, default VInt 0)
env  := string -> option val      (locals + host scalars)
benv := builtin -> Z              (per-thread builtin denotation)
```

Reads/writes are pure function update, not state:

```
env_add e x v   = fun y => if y =? x then Some v else e y
mem_upd m a i v = fun b j => if (b =? a) && (i =? j) then v else m b j
```

Total memories (with a constant default) are deliberate: behavior equality
is proved on *computed traces* (lists, Leibniz equality), so no functional
extensionality axiom is ever needed. The in-bounds gate

```
IDX_MAX := 2^31
idx_ok j := (0 <=? j) && (j <? 2^31)
```

makes out-of-bounds accesses stuck (`None`) on both sides identically;
it is the model counterpart of the frontend's 32-bit index-cast elision
(frontend `README.md` obligation 1). `host_benv := fun _ => 0` since
host-evaluated expressions never use builtins (frontend guarantee).

## 4. Expression semantics

`eval_expr (be:benv) (le:env) (gm:gmem) : expr -> option val`, structural:

| input | result |
|---|---|
| `EVar x` | `le x` |
| `EInt z` / `EFloat f` | `VInt z` / `VFloat f` |
| `EBuiltin b` | `VInt (be b)` |
| `EAddrof x` | `VPtr x` |
| `EUnop UNeg` | negates `VInt` (`-z`) / `VFloat` (`PrimFloat.opp`), else `None` |
| `EUnop UNot` | `VInt`: `1` iff operand `= 0`; else `None` |
| `EBinop` on `VInt,VInt` | `eval_binop_int`: `+,-,*` total; `BDiv`/`BMod` stuck on divisor `0` (`Z.quot`/`Z.rem` otherwise); comparisons yield `VInt 1/0` (`Z.ltb/leb/eqb`); `BAnd`/`BOr` use C truthiness (`≠ 0`) |
| `EBinop` on `VFloat,VFloat` | `eval_binop_float`: IEEE ops via `PrimFloat.add/sub/mul/div`; `BEq/BNe` via `PrimFloat.eqb`; ordering via `PrimFloat.compare` against `FLt/FEq/FGt` (note: `FNotComparable` falls to the `0` arm, matching the code); `BMod/BAnd/BOr` stuck |
| mixed `VInt`/`VFloat` operands | `None` (strict; the corpus is homogeneous) |
| `ESubscript b i` | `b ~> VPtr a`, `i ~> VInt j`, `idx_ok j` required; then `gm a j` |
| `ECall _ _` | always `None` here; calls evaluate only as `atomicAdd` statements |

`eval_list` is the option-monadic map over argument lists.

## 5. Statement semantics

`eval_stmt (be) (le) (gm) : stmt -> option (env * gmem)` with the nested
`go` fixpoint for branch lists (§12); `eval_stmts` folds it over lists:

- `SLet x _ e`: extend `le` on success.
- `SStore`: l-value position is syntactic — `ESubscript` updates `gm`
  (gated by `idx_ok`), `EVar` updates `le`, anything else stuck.
- `SIf c th el`: condition must evaluate to `VInt z`; `z =? 0` selects
  `el`, else `th`. Non-integer conditions stuck.
- `SSync`: identity `(le, gm)`. Vacuous *by hypothesis*: see `WellSync` (§13).
- `atomic_rmw be le gm d v`: destination `d` must be `ESubscript b i`
  with `b ~> VPtr a`, `i ~> VInt j`, `idx_ok j`; the cell must hold the
  same numeric kind as the increment (`VInt`+`VInt` via `Z.add`,
  `VFloat`+`VFloat` via `PrimFloat.add`); anything else stuck.
- `SExpr (ECall "atomicAdd" [d;e])`: `atomic_rmw` (arity ≠ 2 stuck).
  `SExpr` of any other call is stuck (`eval_expr` maps `ECall` to
  `None`); `SExpr` of a non-call expression evaluates and discards.

## 6. Kernel execution

```
mk_benv bid tid bdim gdim : B_tidx↦tid, B_bidx↦bid, B_bdimx↦bdim,
                             B_gdimx↦gdim, all y/z ↦ 0
bind_params ps vs le       : simultaneous parameter binding; arity
                             mismatch stuck
thread_list grid block     : [(bid,tid)] for bid < grid, tid < block,
                             block-major order, via seq/Z.to_nat
run_thread k bdim gdim args (bid,tid) gm :
  bind into empty_env, eval_stmts body, keep final gm
run_threads ... (ts) gm    : left fold of run_thread over ts (option monad)
```

Termination is structural (fixed thread list, loop-free bodies), so no
fuel parameter exists. The fold order is fixed and identical on both
sides; data-race freedom is *assumed* via `WellSync`, not checked —
a racy source still "preserves" into an equally racy target, which is
exactly why `WellSync` is a theorem hypothesis (§13, §14 item 3).

## 7. Observable events (the behavior)

```
event ::= EvMalloc(arr) | EvFree(arr) | EvMemset(arr,n:Z)
        | EvMemcpy(kind,dst,src,vals:list val)
        | EvLaunch(k,grid,block:Z) | EvSync(op:apiOp) | EvHost(text)
```

`read_n m a n` / `write_n m a vs` move element lists between memories.
Per-API rules in `run_host` (arguments evaluate once, up front, via
`eval_list`; branches match on *values*, never on syntax):

- `OpMalloc [VPtr x; VInt _]`: bind `he(x) := VPtr x`, emit `EvMalloc x`.
  (Allocation is nominal: the array is named after the pointer variable;
  memory is infinite and zero-initialized.)
- `OpFree [VPtr a]`: emit `EvFree a` (effect-free).
- `OpMemset [VPtr a; VInt _; VInt z]`: requires `z mod 4 = 0` (else stuck);
  writes `z/4` zeros; emits `EvMemset a z`.
- `OpMemcpy [VPtr dn; VPtr sn; VInt z] + Some kind`: requires `z mod 4 = 0`;
  copies `z/4` elements; `CK_H2D` moves `hm→gm`, `CK_D2H` moves `gm→hm`,
  each emitting `EvMemcpy` *carrying the copied values* (so D2H results
  are observable in the trace); `CK_D2D/CK_H2H` stuck (past v1 corpus).
- The other 12 ops: arguments must evaluate; emit `EvSync (classify f)` —
  vendor-neutral by construction, ordering-only observable.
- `OpOther _`: stuck. `HLaunch`: grid/block must be non-negative `VInt`;
  kernel lookup by name (stuck if absent); threads run; emits `EvLaunch`.
- `HHostCode text _`: emits `EvHost text`, state unchanged.

The 4-byte granularity + exact-division gates mirror the frontend's
`sizeof` rule; `D2D/H2H`, mixed-type atomics, and float conditions are
stuck by design (fail-closed model).

## 8. Programs and initial states

`run_program p he hm gm := run_host (pkernels p) he hm gm (phost p)`.
The theorem universally quantifies over the initial host env and both
memories: host-side values agree *by construction* because `HHostCode`
is byte-identical passthrough — whatever the host does opaquely, it
does equally on both sides.

## 9. Well-formedness (decidable checker)

`wf_expr`: `ECall` restricted to `"atomicAdd"` (recursively); everything
else structurally `true`. `wf_stmt`/`wf_stmts` conjoin over the tree.
`wf_hostNode apis`: API names must belong to the 16-name set, arguments
well-formed, and `cudaMemcpy`/`hipMemcpy` must carry `copyKind`.
`wf_launch_targets`: every launch names an existing kernel with matching
arity (`Nat.eqb` on lengths). `wf_program` conjoins header equality with
the three `Forall` conditions.

## 10. The map and its lemmas (`Map.v`)

`mapApi`: the 16-entry `cuda* → hip*` table (`None` otherwise).
`map_expr/map_stmt/map_hostNode/map_kernel/map_host/map_program` recurse
structurally and are *identity on shapes* (written as explicit recursion,
not `id`, so future divergence is caught, not silent).

- `classify_map : mapApi f = Some h → classify h = classify f`.
  Method: 16 pair-facts (`classify "hipMalloc" = classify "cudaMalloc"`,
  …) each closed by `reflexivity` (conversion computes the `String.eqb`
  tests on literals); main proof walks the table with
  `String.eqb_spec` case splits, discharging each taken branch with its
  pair-fact. This is the lemma that lets the interpreter — which
  branches on `classify`, never on vendor strings — take identical
  branches on both sides.
- `Forall_map_id`, `map_expr_id`, `map_stmt_id` (via `expr_rect2` /
  `stmt_rect2`), `map_stmts_id`, `map_kernel_id`.
- Evaluation invariance, immediate by rewriting with the id lemmas:
  `eval_expr_map`, `eval_list_map`, `eval_stmts_map`.

## 11. Custom induction principles

`expr`/`stmt` nest `list`, so Rocq's default schemes are too weak
(the `register-all` warnings). `Section Recursors` defines
`expr_rect2`/`stmt_rect2` threading `Forall P args` / `Forall Q th/el`
through argument and branch lists (nested-`fix` pattern, §12); all
shape-induction proofs go `induction … using expr_rect2/stmt_rect2`.

## 12. Guard-checker-driven definition style

Mutual `Fixpoint … with …` over statements-through-lists is rejected
("principal argument … instead of …"), so list recursion is expressed
as a *local* `fix go` inside the outer `Fixpoint`, calling back into
the outer function only on elements of subterm lists
(`eval_stmt`, `wf_stmt`, `map_stmt`, the recursors). All `{struct}`
annotations are explicit.

## 13. The main theorem (`Sim.v`)

`WellSync p := Forall (fun k => kshared k = []) (pkernels p)` — no
`__shared__` state, hence barriers vacuous and divergence impossible.

`run_host_map`: for all kernel lists, host lists, and states,
`map_host hs = Some hs' →`
`run_host ks he hm gm hs = run_host (map map_kernel ks) he hm gm hs'`.
Proof by induction on `hs`; the cons case destructs `map_hostNode`/
`map_host` equations, then one subproof per node kind:

- `HApi`: rewrite with `classify_map` (branches equalize) and
  `eval_list_map` (argument values equalize); lockstep `destruct`s on
  the evaluated value list, `classify`, shapes, and the `z mod 4`
  gate — every leaf is `None = None` or a continuation pair closed by
  the IH.
- `HLaunch`: rewrite with `eval_expr_map`/`eval_list_map`;
  destruct grid/block/args values (non-`VInt` leaves stuck identically);
  `find_kernel_map` commutes lookup past the kernel-list map;
  `run_threads_map` (via `map_kernel_id`) equalizes execution; the
  non-negativity guard is destructed once for both sides; continuation
  by IH.
- `HHostCode`: identical text both sides; continuation by IH.

`transpile_correct`:

```
∀ mc mh he hm gm,
  map_program mc = Some mh → WellFormedCuda mc → WellSync mc →
  run_program mc he hm gm = run_program mh he hm gm
  ∧ pheader mh = hip_header
```

by destructing the `map_host` equation inside `map_program`,
applying `run_host_map`, and `reflexivity` for the header conjunct.

## 14. Trust base and explicit non-theorems

- Zero `Admitted`; zero classic axioms. `Print Assumptions` lists only
  `PrimFloat.*` kernel primitives (the IEEE-754 implementation trusted
  base, same category as CompCert's trusted arithmetic).
- What the theorem does **not** cover (documented limitations, not gaps
  in the proof): global-access disjointness across threads is assumed
  for flat thread-indexed code (per-kernel injectivity checking is
  future work); `WellSync` excludes `__shared__` kernels (they still
  transpile — see `tests/extra/` — but outside the proved fragment);
  the model computes in `Z`/binary64 while silicon computes in
  int32/fp32 (sound for in-bounds executions; absolute-vs-silicon
  fidelity is validated by differential GPU runs, not by this theorem);
  host exit codes and host-side computation are opaque by design.

## 15. Schema ↔ Gallina correspondence

`schemas/minicuda-v1.schema.json` §`$defs` maps 1:1 onto
`expr/stmt/kernel/hostNode/program` (JSON `"kind"` tags are the
constructor names; `copyKind` strings are the four `CK_*`; `stream`
`null` is `None`). The two frontend-side assumptions the proof depends
on — 32-bit index-cast elision (justified by `idx_ok` + `WellSync`
in-bounds) and 1-argument `dim3` unwrapping (multi-arg rejected) —
are recorded in `frontend/README.md` and re-stated in §14.
