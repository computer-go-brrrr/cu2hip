(* Map.v — verified core mapping: CUDA program -> HIP program (G3).
   Expression/statement/kernel shapes map structurally (identity on
   everything but API names + header); API names go through the 16-entry
   table. Key lemma: classification is invariant across the rename, so the
   interpreter (which branches on [classify], never on vendor strings)
   takes identical branches on both sides. Rocq 9.2. *)

From Stdlib Require Import List String Bool.
Require Import Cu2Hip.MiniCuda Cu2Hip.MiniHip.
Import ListNotations.
Open Scope string_scope.

(* ---------------- API table ---------------- *)

Definition mapApi (f : string) : option string :=
  if String.eqb f "cudaMalloc" then Some "hipMalloc"
  else if String.eqb f "cudaMemcpy" then Some "hipMemcpy"
  else if String.eqb f "cudaMemset" then Some "hipMemset"
  else if String.eqb f "cudaFree" then Some "hipFree"
  else if String.eqb f "cudaStreamCreate" then Some "hipStreamCreate"
  else if String.eqb f "cudaStreamSynchronize" then Some "hipStreamSynchronize"
  else if String.eqb f "cudaStreamDestroy" then Some "hipStreamDestroy"
  else if String.eqb f "cudaEventCreate" then Some "hipEventCreate"
  else if String.eqb f "cudaEventRecord" then Some "hipEventRecord"
  else if String.eqb f "cudaEventSynchronize" then Some "hipEventSynchronize"
  else if String.eqb f "cudaEventDestroy" then Some "hipEventDestroy"
  else if String.eqb f "cudaEventElapsedTime" then Some "hipEventElapsedTime"
  else if String.eqb f "cudaGetLastError" then Some "hipGetLastError"
  else if String.eqb f "cudaGetErrorString" then Some "hipGetErrorString"
  else if String.eqb f "cudaSetDevice" then Some "hipSetDevice"
  else if String.eqb f "cudaDeviceSynchronize" then Some "hipDeviceSynchronize"
  else None.

(* classify is invariant across the table. Each pair computes to the same
   op; the 16 pair-facts below close by conversion, and the main lemma
   walks the table, closing each taken branch with its pair-fact. *)
Example cm_malloc : classify "hipMalloc" = classify "cudaMalloc". Proof. reflexivity. Qed.
Example cm_memcpy : classify "hipMemcpy" = classify "cudaMemcpy". Proof. reflexivity. Qed.
Example cm_memset : classify "hipMemset" = classify "cudaMemset". Proof. reflexivity. Qed.
Example cm_free : classify "hipFree" = classify "cudaFree". Proof. reflexivity. Qed.
Example cm_screate : classify "hipStreamCreate" = classify "cudaStreamCreate". Proof. reflexivity. Qed.
Example cm_ssync : classify "hipStreamSynchronize" = classify "cudaStreamSynchronize". Proof. reflexivity. Qed.
Example cm_sdestroy : classify "hipStreamDestroy" = classify "cudaStreamDestroy". Proof. reflexivity. Qed.
Example cm_ecreate : classify "hipEventCreate" = classify "cudaEventCreate". Proof. reflexivity. Qed.
Example cm_erecord : classify "hipEventRecord" = classify "cudaEventRecord". Proof. reflexivity. Qed.
Example cm_esync : classify "hipEventSynchronize" = classify "cudaEventSynchronize". Proof. reflexivity. Qed.
Example cm_edestroy : classify "hipEventDestroy" = classify "cudaEventDestroy". Proof. reflexivity. Qed.
Example cm_eelapsed : classify "hipEventElapsedTime" = classify "cudaEventElapsedTime". Proof. reflexivity. Qed.
Example cm_elasterr : classify "hipGetLastError" = classify "cudaGetLastError". Proof. reflexivity. Qed.
Example cm_estr : classify "hipGetErrorString" = classify "cudaGetErrorString". Proof. reflexivity. Qed.
Example cm_setdev : classify "hipSetDevice" = classify "cudaSetDevice". Proof. reflexivity. Qed.
Example cm_devsync : classify "hipDeviceSynchronize" = classify "cudaDeviceSynchronize". Proof. reflexivity. Qed.

Lemma classify_map : forall f h, mapApi f = Some h -> classify h = classify f.
Proof.
  intros f h H. unfold mapApi in H.
  destruct (String.eqb_spec f "cudaMalloc") as [->|_].
  { simpl in H. inversion H. subst. exact cm_malloc. }
  destruct (String.eqb_spec f "cudaMemcpy") as [->|_].
  { simpl in H. inversion H. subst. exact cm_memcpy. }
  destruct (String.eqb_spec f "cudaMemset") as [->|_].
  { simpl in H. inversion H. subst. exact cm_memset. }
  destruct (String.eqb_spec f "cudaFree") as [->|_].
  { simpl in H. inversion H. subst. exact cm_free. }
  destruct (String.eqb_spec f "cudaStreamCreate") as [->|_].
  { simpl in H. inversion H. subst. exact cm_screate. }
  destruct (String.eqb_spec f "cudaStreamSynchronize") as [->|_].
  { simpl in H. inversion H. subst. exact cm_ssync. }
  destruct (String.eqb_spec f "cudaStreamDestroy") as [->|_].
  { simpl in H. inversion H. subst. exact cm_sdestroy. }
  destruct (String.eqb_spec f "cudaEventCreate") as [->|_].
  { simpl in H. inversion H. subst. exact cm_ecreate. }
  destruct (String.eqb_spec f "cudaEventRecord") as [->|_].
  { simpl in H. inversion H. subst. exact cm_erecord. }
  destruct (String.eqb_spec f "cudaEventSynchronize") as [->|_].
  { simpl in H. inversion H. subst. exact cm_esync. }
  destruct (String.eqb_spec f "cudaEventDestroy") as [->|_].
  { simpl in H. inversion H. subst. exact cm_edestroy. }
  destruct (String.eqb_spec f "cudaEventElapsedTime") as [->|_].
  { simpl in H. inversion H. subst. exact cm_eelapsed. }
  destruct (String.eqb_spec f "cudaGetLastError") as [->|_].
  { simpl in H. inversion H. subst. exact cm_elasterr. }
  destruct (String.eqb_spec f "cudaGetErrorString") as [->|_].
  { simpl in H. inversion H. subst. exact cm_estr. }
  destruct (String.eqb_spec f "cudaSetDevice") as [->|_].
  { simpl in H. inversion H. subst. exact cm_setdev. }
  destruct (String.eqb_spec f "cudaDeviceSynchronize") as [->|_].
  { simpl in H. inversion H. subst. exact cm_devsync. }
  simpl in H. discriminate.
Qed.

(* ---------------- structural map (identity on shapes) ---------------- *)
(* Written as explicit recursion (mirroring what the JSON transformer does)
   rather than [id], so future shape divergence is caught here, not silently. *)

Fixpoint map_expr (e : expr) : expr :=
  match e with
  | EVar x => EVar x | EInt z => EInt z | EFloat f => EFloat f
  | EBinop op l r => EBinop op (map_expr l) (map_expr r)
  | EUnop op e1 => EUnop op (map_expr e1)
  | ESubscript b i => ESubscript (map_expr b) (map_expr i)
  | EBuiltin b => EBuiltin b | EAddrof x => EAddrof x
  | ECall f args => ECall f (map (fun a => map_expr a) args)
  end.

Fixpoint map_stmt (s : stmt) : stmt :=
  match s with
  | SLet x t e => SLet x t (map_expr e)
  | SStore t v => SStore (map_expr t) (map_expr v)
  | SIf c th el => SIf (map_expr c) (map map_stmt th) (map map_stmt el)
  | SSync => SSync
  | SExpr e => SExpr (map_expr e)
  end.

Definition map_stmts (ss : list stmt) : list stmt := map map_stmt ss.

Definition map_kernel (k : kernel) : kernel :=
  {| kname := kname k; kparams := kparams k; kshared := kshared k;
     kbody := map_stmts (kbody k) |}.

Definition map_hostNode (n : hostNode) : option hostNode :=
  match n with
  | HApi f args ck =>
      match mapApi f with
      | None => None
      | Some h => Some (HApi h (map map_expr args) ck)
      end
  | HLaunch k g b s args => Some (HLaunch k (map_expr g) (map_expr b) s (map map_expr args))
  | HHostCode t l => Some (HHostCode t l)
  end.

Fixpoint map_host (hs : list hostNode) : option (list hostNode) :=
  match hs with
  | [] => Some []
  | n :: hs' =>
      match map_hostNode n, map_host hs' with
      | Some n', Some hs'' => Some (n' :: hs'')
      | _, _ => None
      end
  end.

Definition map_program (p : program) : option program :=
  match map_host (phost p) with
  | None => None
  | Some hs' =>
      Some {| pheader := hip_header; pkernels := map map_kernel (pkernels p); phost := hs' |}
  end.

(* ---------------- map is identity on shapes ---------------- *)

Lemma Forall_map_id : forall (A : Type) (f : A -> A) (l : list A),
  Forall (fun x => f x = x) l -> map f l = l.
Proof.
  intros A f l H. induction H as [|a l' Ha _ IH]; simpl; congruence.
Qed.

Lemma map_expr_id : forall e, map_expr e = e.
Proof.
  intro e.
  induction e using expr_rect2 with (P := fun e => map_expr e = e);
    intros; simpl.
  - reflexivity.
  - reflexivity.
  - reflexivity.
  - congruence.
  - congruence.
  - congruence.
  - reflexivity.
  - reflexivity.
  - f_equal. apply Forall_map_id. assumption.
Qed.

Lemma Forall_map_stmt_id : forall (l : list stmt),
  Forall (fun x => map_stmt x = x) l -> map map_stmt l = l.
Proof.
  intros l H. induction H as [|a l' Ha _ IH]; simpl; congruence.
Qed.

Lemma map_stmt_id : forall s, map_stmt s = s.
Proof.
  intro s.
  induction s using stmt_rect2 with (P := fun _ => True) (Q := fun s => map_stmt s = s);
    intros; try exact I; simpl.
  - repeat rewrite map_expr_id. reflexivity.
  - repeat rewrite map_expr_id. reflexivity.
  - repeat rewrite map_expr_id. f_equal; f_equal;
      apply Forall_map_stmt_id; assumption.
  - reflexivity.
  - repeat rewrite map_expr_id. reflexivity.
Qed.

Lemma map_stmts_id : forall ss, map_stmts ss = ss.
Proof.
  intros ss. unfold map_stmts. induction ss as [|s ss' IH]; simpl.
  - reflexivity.
  - rewrite map_stmt_id, IH. reflexivity.
Qed.

Lemma map_kernel_id : forall k, map_kernel k = k.
Proof.
  intros k. destruct k as [n ps sh b]. unfold map_kernel. simpl.
  rewrite map_stmts_id. reflexivity.
Qed.

(* Evaluation is invariant across the shape map (immediate by the id lemmas). *)

Lemma eval_expr_map : forall be le gm e,
  eval_expr be le gm (map_expr e) = eval_expr be le gm e.
Proof. intros. rewrite map_expr_id. reflexivity. Qed.

Lemma eval_list_map : forall be le gm es,
  eval_list be le gm (map map_expr es) = eval_list be le gm es.
Proof.
  induction es as [|e es' IH]; simpl; auto.
  rewrite map_expr_id, IH. reflexivity.
Qed.

Lemma eval_stmts_map : forall be le gm ss,
  eval_stmts be le gm (map_stmts ss) = eval_stmts be le gm ss.
Proof. intros. rewrite map_stmts_id. reflexivity. Qed.
