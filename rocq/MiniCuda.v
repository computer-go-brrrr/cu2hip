(* MiniCuda.v — MiniCUDA AST + executable semantics (G3).
   Mirrors schemas/minicuda-v1.schema.json 1:1. MiniHip.v reuses this AST;
   only API names / header differ (see Map.v). Rocq 9.2. *)

From Stdlib Require Import ZArith List String Bool Lia.
From Stdlib Require Import Floats.
Import ListNotations.
Open Scope Z_scope.
Open Scope string_scope.

(* ---------------- values ---------------- *)

Inductive val : Type :=
| VInt (z : Z)
| VFloat (f : PrimFloat.float)
| VPtr (arr : string)
| VUnit.

(* ---------------- surface types (checked, not evaluated) ---------------- *)

Inductive scalarTy := TyInt | TyFloat | TyDouble.

Inductive binop :=
| BAdd | BSub | BMul | BDiv | BMod
| BLt | BLe | BGt | BGe | BEq | BNe
| BAnd | BOr.

Inductive unop := UNeg | UNot.

Inductive builtin :=
| B_tidx | B_tidy | B_tidz
| B_bidx | B_bidy | B_bidz
| B_bdimx | B_bdimy | B_bdimz
| B_gdimx | B_gdimy | B_gdimz.

(* ---------------- expressions ---------------- *)

Inductive expr :=
| EVar (x : string)
| EInt (z : Z)
| EFloat (f : PrimFloat.float)
| EBinop (op : binop) (l r : expr)
| EUnop (op : unop) (e : expr)
| ESubscript (base idx : expr)
| EBuiltin (b : builtin)
| EAddrof (x : string)
| ECall (f : string) (args : list expr).  (* well-formed: only "atomicAdd" *)

(* ---------------- statements ---------------- *)

Inductive stmt :=
| SLet (x : string) (ty : scalarTy) (e : expr)
| SStore (tgt v : expr)
| SIf (c : expr) (th el : list stmt)
| SSync
| SExpr (e : expr).

Record param := { pname : string; pty : scalarTy; pptr : bool }.
Record sharedDecl := { sname : string; sty : scalarTy; ssize : Z }.
Record kernel :=
  { kname : string; kparams : list param; kshared : list sharedDecl; kbody : list stmt }.

(* ---------------- host ---------------- *)

Inductive copyKind := CK_H2D | CK_D2H | CK_D2D | CK_H2H.

Inductive hostNode :=
| HApi (f : string) (args : list expr) (ck : option copyKind)
| HLaunch (k : string) (grid block : expr) (stream : option string) (args : list expr)
| HHostCode (text loc : string).  (* opaque passthrough, byte-identical *)

Record program :=
  { pheader : string; pkernels : list kernel; phost : list hostNode }.

Inductive diagnostic := Diag (code feature loc hint : string).
Record envelope :=
  { esource : string; eprogram : option program; ediags : list diagnostic }.

(* ---------------- API classification ---------------- *)
(* Both cuda* and hip* names classify to the SAME op, so the interpreter
   branches on ops, never on vendor strings. Preservation across the
   rename is then structural (see Map.v: classify_map). *)

Inductive apiOp :=
| OpMalloc | OpMemcpy | OpMemset | OpFree
| OpStreamCreate | OpStreamSync | OpStreamDestroy
| OpEventCreate | OpEventRecord | OpEventSync | OpEventDestroy | OpEventElapsed
| OpGetLastError | OpGetErrorString | OpSetDevice | OpDeviceSync
| OpOther (f : string).

Definition classify (f : string) : apiOp :=
  if String.eqb f "cudaMalloc" || String.eqb f "hipMalloc" then OpMalloc
  else if String.eqb f "cudaMemcpy" || String.eqb f "hipMemcpy" then OpMemcpy
  else if String.eqb f "cudaMemset" || String.eqb f "hipMemset" then OpMemset
  else if String.eqb f "cudaFree" || String.eqb f "hipFree" then OpFree
  else if String.eqb f "cudaStreamCreate" || String.eqb f "hipStreamCreate" then OpStreamCreate
  else if String.eqb f "cudaStreamSynchronize" || String.eqb f "hipStreamSynchronize" then OpStreamSync
  else if String.eqb f "cudaStreamDestroy" || String.eqb f "hipStreamDestroy" then OpStreamDestroy
  else if String.eqb f "cudaEventCreate" || String.eqb f "hipEventCreate" then OpEventCreate
  else if String.eqb f "cudaEventRecord" || String.eqb f "hipEventRecord" then OpEventRecord
  else if String.eqb f "cudaEventSynchronize" || String.eqb f "hipEventSynchronize" then OpEventSync
  else if String.eqb f "cudaEventDestroy" || String.eqb f "hipEventDestroy" then OpEventDestroy
  else if String.eqb f "cudaEventElapsedTime" || String.eqb f "hipEventElapsedTime" then OpEventElapsed
  else if String.eqb f "cudaGetLastError" || String.eqb f "hipGetLastError" then OpGetLastError
  else if String.eqb f "cudaGetErrorString" || String.eqb f "hipGetErrorString" then OpGetErrorString
  else if String.eqb f "cudaSetDevice" || String.eqb f "hipSetDevice" then OpSetDevice
  else if String.eqb f "cudaDeviceSynchronize" || String.eqb f "hipDeviceSynchronize" then OpDeviceSync
  else OpOther f.

(* ---------------- memories & environments ---------------- *)
(* Memories are total functions (default VInt 0). Behavior equality is
   proved on computed traces, never requiring functional extensionality. *)

Definition gmem := string -> Z -> val.
Definition hmem := string -> Z -> val.
Definition env := string -> option val.   (* locals + host scalars *)
Definition benv := builtin -> Z.          (* builtin denotation per thread *)

Definition empty_env : env := fun _ => None.
Definition env_add (e : env) (x : string) (v : val) : env :=
  fun y => if String.eqb y x then Some v else e y.
Definition mem_upd (m : string -> Z -> val) (a : string) (i : Z) (v : val) :=
  fun b j => if andb (String.eqb b a) (Z.eqb i j) then v else m b j.
Definition default_mem : string -> Z -> val := fun _ _ => VInt 0.

(* In-bounds index gate (frontend README obligation 1): conversions between
   32-bit uint and int are the identity on in-bounds indices. Out-of-bounds
   executions are stuck (no behavior) on BOTH sides. *)
Definition IDX_MAX : Z := 2 ^ 31.
Definition idx_ok (j : Z) : bool := (Z.leb 0 j) && (Z.ltb j IDX_MAX).

(* Host-evaluated expressions never use builtins (frontend guarantee);
   denote them 0 so evaluation is total on that fragment. *)
Definition host_benv : benv := fun _ => 0.

(* ---------------- expression evaluation ---------------- *)

Definition eval_binop_int (op : binop) (a b : Z) : option val :=
  match op with
  | BAdd => Some (VInt (a + b)) | BSub => Some (VInt (a - b)) | BMul => Some (VInt (a * b))
  | BDiv => if Z.eqb b 0 then None else Some (VInt (Z.quot a b))
  | BMod => if Z.eqb b 0 then None else Some (VInt (Z.rem a b))
  | BLt => Some (VInt (if Z.ltb a b then 1 else 0))
  | BLe => Some (VInt (if Z.leb a b then 1 else 0))
  | BGt => Some (VInt (if Z.ltb b a then 1 else 0))
  | BGe => Some (VInt (if Z.leb b a then 1 else 0))
  | BEq => Some (VInt (if Z.eqb a b then 1 else 0))
  | BNe => Some (VInt (if Z.eqb a b then 0 else 1))
  | BAnd => Some (VInt (if andb (negb (Z.eqb a 0)) (negb (Z.eqb b 0)) then 1 else 0))
  | BOr => Some (VInt (if orb (negb (Z.eqb a 0)) (negb (Z.eqb b 0)) then 1 else 0))
  end.

Definition eval_binop_float (op : binop) (a b : PrimFloat.float) : option val :=
  match op with
  | BAdd => Some (VFloat (PrimFloat.add a b)) | BSub => Some (VFloat (PrimFloat.sub a b))
  | BMul => Some (VFloat (PrimFloat.mul a b)) | BDiv => Some (VFloat (PrimFloat.div a b))
  | BEq => Some (VInt (if PrimFloat.eqb a b then 1 else 0))
  | BNe => Some (VInt (if PrimFloat.eqb a b then 0 else 1))
  | BLt => Some (VInt (match PrimFloat.compare a b with FLt => 1 | _ => 0 end))
  | BLe => Some (VInt (match PrimFloat.compare a b with FLt => 1 | FEq => 1 | _ => 0 end))
  | BGt => Some (VInt (match PrimFloat.compare a b with FGt => 1 | _ => 0 end))
  | BGe => Some (VInt (match PrimFloat.compare a b with FGt => 1 | FEq => 1 | _ => 0 end))
  | _ => None
  end.

Fixpoint eval_expr (be : benv) (le : env) (gm : gmem) (e : expr) : option val :=
  match e with
  | EVar x => le x
  | EInt z => Some (VInt z)
  | EFloat f => Some (VFloat f)
  | EBuiltin b => Some (VInt (be b))
  | EAddrof x => Some (VPtr x)
  | EUnop UNeg e1 =>
      match eval_expr be le gm e1 with
      | Some (VInt z) => Some (VInt (-z))
      | Some (VFloat f) => Some (VFloat (PrimFloat.opp f))
      | _ => None
      end
  | EUnop UNot e1 =>
      match eval_expr be le gm e1 with
      | Some (VInt z) => Some (VInt (if Z.eqb z 0 then 1 else 0))
      | _ => None
      end
  | EBinop op l r =>
      match eval_expr be le gm l, eval_expr be le gm r with
      | Some (VInt a), Some (VInt b) => eval_binop_int op a b
      | Some (VFloat a), Some (VFloat b) => eval_binop_float op a b
      | _, _ => None
      end
  | ESubscript b i =>
      match eval_expr be le gm b, eval_expr be le gm i with
      | Some (VPtr a), Some (VInt j) =>
          if idx_ok j then Some (gm a j) else None
      | _, _ => None
      end
  | ECall _ _ => None  (* calls evaluate only as atomicAdd statements (SExpr) *)
  end.

Fixpoint eval_list (be : benv) (le : env) (gm : gmem) (es : list expr) : option (list val) :=
  match es with
  | [] => Some []
  | e :: es' =>
      match eval_expr be le gm e, eval_list be le gm es' with
      | Some v, Some vs => Some (v :: vs)
      | _, _ => None
      end
  end.

(* ---------------- statement evaluation ---------------- *)

Definition atomic_rmw (be : benv) (le : env) (gm : gmem) (d v : expr) : option (env * gmem) :=
  match d with
  | ESubscript b i =>
      match eval_expr be le gm b, eval_expr be le gm i, eval_expr be le gm v with
      | Some (VPtr a), Some (VInt j), Some (VInt w) =>
          if idx_ok j then
            match gm a j with
            | VInt old => Some (le, mem_upd gm a j (VInt (old + w)))
            | _ => None
            end
          else None
      | Some (VPtr a), Some (VInt j), Some (VFloat w) =>
          if idx_ok j then
            match gm a j with
            | VFloat old => Some (le, mem_upd gm a j (VFloat (PrimFloat.add old w)))
            | _ => None
            end
          else None
      | _, _, _ => None
      end
  | _ => None
  end.

(* eval_stmt is structurally recursive on [s]; branch lists go through the
   local [go] fixpoint, which may call back into [eval_stmt] only on
   elements of those subterm lists (accepted nesting pattern). *)
Fixpoint eval_stmt (be : benv) (le : env) (gm : gmem) (s : stmt) {struct s} : option (env * gmem) :=
  let fix go (le : env) (gm : gmem) (ss : list stmt) : option (env * gmem) :=
    match ss with
    | [] => Some (le, gm)
    | s' :: ss' =>
        match eval_stmt be le gm s' with
        | None => None
        | Some (le', gm') => go le' gm' ss'
        end
    end in
  match s with
  | SLet x _ e =>
      match eval_expr be le gm e with
      | Some v => Some (env_add le x v, gm)
      | None => None
      end
  | SStore t v =>
      match t with
      | ESubscript b i =>
          match eval_expr be le gm b, eval_expr be le gm i, eval_expr be le gm v with
          | Some (VPtr a), Some (VInt j), Some w =>
              if idx_ok j then Some (le, mem_upd gm a j w) else None
          | _, _, _ => None
          end
      | EVar x =>
          match eval_expr be le gm v with
          | Some w => Some (env_add le x w, gm)
          | None => None
          end
      | _ => None
      end
  | SIf c th el =>
      match eval_expr be le gm c with
      | Some (VInt z) =>
          if Z.eqb z 0 then go le gm el else go le gm th
      | _ => None
      end
  | SSync => Some (le, gm)  (* vacuous under WellSync (no shared state); see Sim.v *)
  | SExpr (ECall f args) =>
      if String.eqb f "atomicAdd" then
        match args with
        | [d; e] => atomic_rmw be le gm d e
        | _ => None
        end
      else
        match eval_expr be le gm (ECall f args) with
        | Some _ => Some (le, gm)
        | None => None
        end
  | SExpr e =>
      match eval_expr be le gm e with
      | Some _ => Some (le, gm)
      | None => None
      end
  end.

Fixpoint eval_stmts (be : benv) (le : env) (gm : gmem) (ss : list stmt) {struct ss}
    : option (env * gmem) :=
  match ss with
  | [] => Some (le, gm)
  | s :: ss' =>
      match eval_stmt be le gm s with
      | None => None
      | Some (le', gm') => eval_stmts be le' gm' ss'
      end
  end.

(* ---------------- kernel execution ---------------- *)
(* Straight-line kernels terminate structurally; threads fold in fixed
   (block, thread) order over shared device memory. Barrier divergence and
   races are excluded by the WellSync hypothesis (Sim.v), not modeled here. *)

Definition mk_benv (bid tid bdim gdim : Z) : benv :=
  fun b => match b with
           | B_tidx => tid | B_tidy => 0 | B_tidz => 0
           | B_bidx => bid | B_bidy => 0 | B_bidz => 0
           | B_bdimx => bdim | B_bdimy => 0 | B_bdimz => 0
           | B_gdimx => gdim | B_gdimy => 0 | B_gdimz => 0
           end.

Fixpoint bind_params (ps : list param) (vs : list val) (le : env) : option env :=
  match ps, vs with
  | [], [] => Some le
  | p :: ps', v :: vs' => bind_params ps' vs' (env_add le (pname p) v)
  | _, _ => None
  end.

Definition run_thread (k : kernel) (bdim gdim : Z) (args : list val)
           (bt : Z * Z) (gm : gmem) : option gmem :=
  let (bid, tid) := bt in
  match bind_params (kparams k) args empty_env with
  | None => None
  | Some le =>
      match eval_stmts (mk_benv bid tid bdim gdim) le gm (kbody k) with
      | None => None
      | Some (_, gm') => Some gm'
      end
  end.

Definition thread_list (grid block : Z) : list (Z * Z) :=
  flat_map (fun bi => map (fun ti => (Z.of_nat bi, Z.of_nat ti)) (seq 0 (Z.to_nat block)))
           (seq 0 (Z.to_nat grid)).

Fixpoint run_threads (k : kernel) (bdim gdim : Z) (args : list val)
         (ts : list (Z * Z)) (gm : gmem) : option gmem :=
  match ts with
  | [] => Some gm
  | t :: ts' =>
      match run_thread k bdim gdim args t gm with
      | None => None
      | Some gm' => run_threads k bdim gdim args ts' gm'
      end
  end.

(* ---------------- observable events ---------------- *)

Inductive event :=
| EvMalloc (arr : string)
| EvFree (arr : string)
| EvMemset (arr : string) (n : Z)
| EvMemcpy (kind : copyKind) (dst src : string) (vals : list val)
| EvLaunch (k : string) (grid block : Z)
| EvSync (op : apiOp)  (* vendor-neutral: classify is rename-invariant *)
| EvHost (text : string).  (* opaque passthrough marker; text identical both sides *)

Fixpoint read_n (m : string -> Z -> val) (a : string) (n : nat) : list val :=
  match n with
  | O => []
  | S n' => read_n m a n' ++ [m a (Z.of_nat n')]
  end.

Fixpoint write_n_aux (m : string -> Z -> val) (a : string) (off : nat) (vs : list val) :=
  match vs with
  | [] => m
  | v :: vs' => write_n_aux (mem_upd m a (Z.of_nat off) v) a (S off) vs'
  end.
Definition write_n m a vs := write_n_aux m a O vs.

Definition find_kernel (ks : list kernel) (kn : string) : option kernel :=
  find (fun k => String.eqb (kname k) kn) ks.

(* ---------------- host evaluation ---------------- *)
(* Initial host env/memories are universally quantified in the theorem:
   host Code is byte-identical passthrough, so all host-side values agree. *)

Fixpoint run_host (ks : list kernel) (he : env) (hm : hmem) (gm : gmem)
         (hs : list hostNode) : option (list event * hmem * gmem) :=
  match hs with
  | [] => Some ([], hm, gm)
  | h :: hs' =>
      match h with
      | HHostCode text _ =>
          match run_host ks he hm gm hs' with
          | None => None
          | Some (ev, hm', gm') => Some (EvHost text :: ev, hm', gm')
          end
      | HLaunch kn g b _ args =>
          match eval_expr host_benv he gm g, eval_expr host_benv he gm b,
                eval_list host_benv he gm args with
          | Some (VInt gv), Some (VInt bv), Some vargs =>
              if orb (Z.ltb gv 0) (Z.ltb bv 0) then None
              else
                match find_kernel ks kn with
                | None => None
                | Some k =>
                    match run_threads k bv gv vargs (thread_list gv bv) gm with
                    | None => None
                    | Some gm' =>
                        match run_host ks he hm gm' hs' with
                        | None => None
                        | Some (ev, hm', gm'') => Some (EvLaunch kn gv bv :: ev, hm', gm'')
                        end
                    end
                end
          | _, _, _ => None
          end
      | HApi f args ck =>
          (* Arguments evaluate ONCE, up front; branches match on VALUES, so
             both sides of the transpiler take identical branches (the only
             vendor dependence is [classify f], handled by Map.classify_map). *)
          match eval_list host_benv he gm args with
          | None => None
          | Some vargs =>
              match classify f with
              | OpOther _ => None
              | OpMalloc =>
                  match vargs with
                  | [VPtr x; VInt _] =>
                      match run_host ks (env_add he x (VPtr x)) hm gm hs' with
                      | None => None
                      | Some (ev, hm', gm') => Some (EvMalloc x :: ev, hm', gm')
                      end
                  | _ => None
                  end
              | OpFree =>
                  match vargs with
                  | [VPtr a] =>
                      match run_host ks he hm gm hs' with
                      | None => None
                      | Some (ev, hm', gm') => Some (EvFree a :: ev, hm', gm')
                      end
                  | _ => None
                  end
              | OpMemset =>
                  match vargs with
                  | [VPtr a; VInt _; VInt z] =>
                      if negb (Z.eqb (Z.modulo z 4) 0) then None
                      else
                        match run_host ks he hm (write_n gm a (repeat (VInt 0) (Z.to_nat (Z.div z 4)))) hs' with
                        | None => None
                        | Some (ev, hm', gm'') => Some (EvMemset a z :: ev, hm', gm'')
                        end
                  | _ => None
                  end
              | OpMemcpy =>
                  match vargs, ck with
                  | [VPtr dn; VPtr sn; VInt z], Some kind =>
                      if negb (Z.eqb (Z.modulo z 4) 0) then None
                      else
                        match kind with
                        | CK_H2D =>
                            match run_host ks he hm (write_n gm dn (read_n hm sn (Z.to_nat (Z.div z 4)))) hs' with
                            | None => None
                            | Some (ev, hm', gm'') =>
                                Some (EvMemcpy kind dn sn (read_n hm sn (Z.to_nat (Z.div z 4))) :: ev, hm', gm'')
                            end
                        | CK_D2H =>
                            match run_host ks he (write_n hm dn (read_n gm sn (Z.to_nat (Z.div z 4)))) gm hs' with
                            | None => None
                            | Some (ev, hm'', gm') =>
                                Some (EvMemcpy kind dn sn (read_n gm sn (Z.to_nat (Z.div z 4))) :: ev, hm'', gm')
                            end
                        | _ => None  (* D2D/H2H retargeted past v1 corpus *)
                        end
                  | _, _ => None
                  end
              | _ =>
                  (* remaining 12 sync/config/query APIs: only ordering is observable *)
                  match run_host ks he hm gm hs' with
                  | None => None
                  | Some (ev, hm', gm') => Some (EvSync (classify f) :: ev, hm', gm')
                  end
              end
          end
      end
  end.

Definition run_program (p : program) (he : env) (hm : hmem) (gm : gmem) :=
  run_host (pkernels p) he hm gm (phost p).

(* ---------------- custom induction principles ---------------- *)
(* [expr] and [stmt] nest [list], so the default schemes are too weak
   (see the register-all warning). These recursors thread [Forall]
   through argument/branch lists; Map.v and Sim.v induct [using] them. *)

Section Recursors.
  Variable P : expr -> Prop.
  Variable Q : stmt -> Prop.

  Hypothesis HVar : forall x, P (EVar x).
  Hypothesis HInt : forall z, P (EInt z).
  Hypothesis HFloat : forall f, P (EFloat f).
  Hypothesis HBinop : forall op l r, P l -> P r -> P (EBinop op l r).
  Hypothesis HUnop : forall op e1, P e1 -> P (EUnop op e1).
  Hypothesis HSub : forall b i, P b -> P i -> P (ESubscript b i).
  Hypothesis HBuiltin : forall b, P (EBuiltin b).
  Hypothesis HAddrof : forall x, P (EAddrof x).
  Hypothesis HCall : forall f args, Forall P args -> P (ECall f args).

  Hypothesis HLet : forall x t e, P e -> Q (SLet x t e).
  Hypothesis HStore : forall t v, P t -> P v -> Q (SStore t v).
  Hypothesis HIf : forall c th el, P c -> Forall Q th -> Forall Q el -> Q (SIf c th el).
  Hypothesis HSync : Q SSync.
  Hypothesis HExpr : forall e, P e -> Q (SExpr e).

  Fixpoint expr_rect2 (e : expr) {struct e} : P e :=
    let fix go (l : list expr) : Forall P l :=
      match l as l0 return Forall P l0 with
      | [] => Forall_nil _
      | a :: l' => Forall_cons a (expr_rect2 a) (go l')
      end in
    match e as e0 return P e0 with
    | EVar x => HVar x
    | EInt z => HInt z
    | EFloat f => HFloat f
    | EBinop op l r => HBinop op l r (expr_rect2 l) (expr_rect2 r)
    | EUnop op e1 => HUnop op e1 (expr_rect2 e1)
    | ESubscript b i => HSub b i (expr_rect2 b) (expr_rect2 i)
    | EBuiltin b => HBuiltin b
    | EAddrof x => HAddrof x
    | ECall f args => HCall f args (go args)
    end.

  Fixpoint stmt_rect2 (s : stmt) {struct s} : Q s :=
    let fix go (l : list stmt) : Forall Q l :=
      match l as l0 return Forall Q l0 with
      | [] => Forall_nil _
      | a :: l' => Forall_cons a (stmt_rect2 a) (go l')
      end in
    match s as s0 return Q s0 with
    | SLet x t e => HLet x t e (expr_rect2 e)
    | SStore t v => HStore t v (expr_rect2 t) (expr_rect2 v)
    | SIf c th el => HIf c th el (expr_rect2 c) (go th) (go el)
    | SSync => HSync
    | SExpr e => HExpr e (expr_rect2 e)
    end.
End Recursors.

(* ---------------- well-formedness (parameterized by API set) ---------------- *)

Fixpoint wf_expr (e : expr) : bool :=
  match e with
  | ECall f args => andb (String.eqb f "atomicAdd") (forallb wf_expr args)
  | EBinop _ l r => andb (wf_expr l) (wf_expr r)
  | EUnop _ e1 => wf_expr e1
  | ESubscript b i => andb (wf_expr b) (wf_expr i)
  | _ => true
  end.

Fixpoint wf_stmt (s : stmt) : bool :=
  let fix go (l : list stmt) : bool :=
    match l with
    | [] => true
    | s' :: l' => wf_stmt s' && go l'
    end in
  match s with
  | SLet _ _ e => wf_expr e
  | SStore t v => wf_expr t && wf_expr v
  | SIf c th el => wf_expr c && go th && go el
  | SSync => true
  | SExpr e => wf_expr e
  end.

Fixpoint wf_stmts (ss : list stmt) : bool :=
  match ss with
  | [] => true
  | s :: ss' => wf_stmt s && wf_stmts ss'
  end.

Definition wf_kernel (k : kernel) : bool := wf_stmts (kbody k).

Definition wf_hostNode (apis : list string) (n : hostNode) : bool :=
  match n with
  | HApi f args ck =>
      andb (existsb (String.eqb f) apis)
           (andb (forallb wf_expr args)
                 match f, ck with
                 | "cudaMemcpy", Some _ => true
                 | "hipMemcpy", Some _ => true
                 | "cudaMemcpy", None => false
                 | "hipMemcpy", None => false
                 | _, _ => true
                 end)
  | HLaunch _ g b _ args =>
      andb (wf_expr g) (andb (wf_expr b) (forallb wf_expr args))
  | HHostCode _ _ => true
  end.

Definition find_kernel_bool (ks : list kernel) (kn : string) : option kernel :=
  find (fun k => String.eqb (kname k) kn) ks.

Definition wf_launch_targets (p : program) : bool :=
  forallb (fun n => match n with
                    | HLaunch kn _ _ _ args =>
                        match find_kernel_bool (pkernels p) kn with
                        | None => false
                        | Some k => Nat.eqb (List.length args) (List.length (kparams k))
                        end
                    | _ => true
                    end) (phost p).

Definition wf_program (apis : list string) (header : string) (p : program) : Prop :=
  pheader p = header /\ Forall (fun k => wf_kernel k = true) (pkernels p) /\
  Forall (fun n => wf_hostNode apis n = true) (phost p) /\
  wf_launch_targets p = true.
