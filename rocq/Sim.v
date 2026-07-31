(* Sim.v — semantic preservation: the v1 transpiler theorem (G3).
   Statement: a well-formed, well-synchronized MiniCUDA program and its
   transpiled MiniHIP image have IDENTICAL observable behaviors
   (event traces) from identical initial host/device states, and the
   emitted header is exactly hip/hip_runtime.h.

   Scope honesty (see SRS section 5):
   - WellSync_v1 = no __shared__ state in any kernel. Barriers are then
     vacuous, barrier divergence impossible, and the sequential thread-fold
     semantics is faithful ON race-free programs.
   - Global-access disjointness across threads (flat thread-indexed code)
     is ASSUMED for v1, not checked: the model threads one shared gmem
     through threads in fixed order, so a racy source would still
     "preserve" into an equally racy target. A per-kernel injectivity
     checker is tracked future work (see rocq/README.md).
   - host_code is byte-identical passthrough: host-side values agree by
     construction (initial env/memories are universally quantified).
   - 32-bit index-cast elision and 1-arg dim3 unwrapping are frontend-side
     assumptions (frontend/README.md); the model computes in Z throughout,
     identically on both sides. Rocq 9.2. *)

From Stdlib Require Import List String Bool Lia ZArith.
Require Import Cu2Hip.MiniCuda Cu2Hip.MiniHip Cu2Hip.Map.
Import ListNotations.
Open Scope string_scope.

Definition WellSync (p : program) : Prop :=
  Forall (fun k => kshared k = []%list) (pkernels p).

(* ---------- evaluation invariance across the shape map ---------- *)

Lemma eval_list_map : forall be le gm es,
  eval_list be le gm (map map_expr es) = eval_list be le gm es.
Proof.
  induction es as [|e es' IH]; simpl; auto.
  rewrite map_expr_id, IH. reflexivity.
Qed.

Lemma find_kernel_map : forall ks kn,
  find_kernel (map map_kernel ks) kn =
  match find_kernel ks kn with
  | Some k => Some (map_kernel k)
  | None => None
  end.
Proof.
  intros ks kn. induction ks as [|k ks' IH].
  - reflexivity.
  - simpl. unfold map_kernel at 1. simpl.
    destruct (String.eqb (kname k) kn).
    + reflexivity.
    + simpl. rewrite IH. destruct (find_kernel ks' kn); reflexivity.
Qed.

Lemma run_threads_map : forall k bdim gdim args ts gm,
  run_threads (map_kernel k) bdim gdim args ts gm = run_threads k bdim gdim args ts gm.
Proof.
  intros. rewrite map_kernel_id. reflexivity.
Qed.

(* ---------- host-run preservation, by induction on host nodes ---------- *)

Lemma run_host_map : forall ks hs hs' he hm gm,
  map_host hs = Some hs' ->
  run_host ks he hm gm hs =
  run_host (map map_kernel ks) he hm gm hs'.
Proof.
  intros ks hs. induction hs as [|h tl IH]; intros hs' he hm gm Hmap; simpl in *.
  - inversion Hmap. subst. reflexivity.
  - destruct (map_hostNode h) as [h'|] eqn:E1; try discriminate.
    destruct (map_host tl) as [tl'|] eqn:E2; try discriminate.
    inversion Hmap. subst. clear Hmap.
    destruct h as [f args ck|kn g b s args|t l].
    + (* HApi: classify is invariant; argument lists evaluate identically.
         Lockstep destructs cover both sides at once; every leaf is either
         None=None or a continuation pair closed by the IH. *)
      destruct (mapApi f) as [h''|] eqn:E3.
      * simpl in E1. rewrite E3 in E1. inversion E1. subst. clear E1.
        simpl. rewrite (classify_map f h'' E3). rewrite eval_list_map.
        destruct (eval_list host_benv he gm args) as [vargs|]; [|reflexivity].
        destruct (classify f).
        -- (* OpMalloc *)
           destruct vargs as [|v1 [|v2 [|]]]; simpl; try reflexivity.
           destruct v1 as [z1|f1|s1|u1]; destruct v2 as [z2|f2|s2|u2];
             simpl; try reflexivity.
           rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- (* OpMemcpy *)
           destruct vargs as [|v1 [|v2 [|v3 [|]]]]; simpl; try reflexivity.
           destruct ck as [k|]; simpl; try reflexivity.
           destruct v1 as [a1|b1|c1|d1]; destruct v2 as [a2|b2|c2|d2];
             destruct v3 as [z|fl|sn|u]; simpl; try reflexivity.
           destruct k; simpl.
           { destruct (Z.eqb (Z.modulo z 4) 0); simpl; try reflexivity.
             rewrite (IH _ _ _ _ (eq_refl _)). reflexivity. }
           { destruct (Z.eqb (Z.modulo z 4) 0); simpl; try reflexivity.
             rewrite (IH _ _ _ _ (eq_refl _)). reflexivity. }
           { reflexivity. }
           { reflexivity. }
        -- (* OpMemset *)
           destruct vargs as [|v1 [|v2 [|v3 [|]]]]; simpl; try reflexivity.
           destruct v1 as [a1|b1|c1|d1]; destruct v2 as [a2|b2|c2|d2];
             destruct v3 as [z|fl|sn|u]; simpl; try reflexivity.
           destruct (Z.eqb (Z.modulo z 4) 0); simpl; try reflexivity.
           rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- (* OpFree *)
           destruct vargs as [|v1 [|]]; simpl; try reflexivity.
           destruct v1 as [z1|f1|s1|u1]; simpl; try reflexivity.
           rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- rewrite (IH _ _ _ _ (eq_refl _)). reflexivity.
        -- reflexivity.
      * simpl in E1. rewrite E3 in E1. discriminate.
    + (* HLaunch: grid/block/args evaluate identically; kernel lookup commutes. *)
      inversion E1. subst. clear E1.
      simpl. rewrite eval_expr_map. rewrite eval_expr_map. rewrite eval_list_map.
      destruct (eval_expr host_benv he gm g) as [vg|]; try (simpl; reflexivity).
      destruct vg as [gv|gf|gs|gu]; try (simpl; reflexivity).
      destruct (eval_expr host_benv he gm b) as [vb|]; try (simpl; reflexivity).
      destruct vb as [bv|bf|bs|bu]; try (simpl; reflexivity).
      destruct (eval_list host_benv he gm args) as [vargs|]; try (simpl; reflexivity).
      rewrite find_kernel_map.
      destruct (find_kernel ks kn) as [k|]; simpl; try reflexivity.
      destruct (orb (Z.ltb gv 0) (Z.ltb bv 0)); simpl; try reflexivity.
      rewrite run_threads_map.
      destruct (run_threads k bv gv vargs (thread_list gv bv) gm) as [gm'|];
        simpl; try reflexivity.
      pose proof (IH tl' he hm gm' (eq_refl _)) as IH2. rewrite IH2. reflexivity.
    + (* HHostCode: byte-identical passthrough. *)
      inversion E1. subst. clear E1.
      simpl. pose proof (IH tl' he hm gm (eq_refl _)) as IH2. rewrite IH2. reflexivity.
Qed.

(* ---------- the v1 transpiler theorem ---------- *)

Theorem transpile_correct : forall mc mh he hm gm,
  map_program mc = Some mh ->
  WellFormedCuda mc ->
  WellSync mc ->
  run_program mc he hm gm = run_program mh he hm gm /\
  pheader mh = hip_header.
Proof.
  intros mc mh he hm gm Hmap Hwf Hsync.
  unfold map_program in Hmap.
  destruct (map_host (phost mc)) as [hs'|] eqn:E; try discriminate.
  inversion Hmap. subst. clear Hmap.
  split.
  - unfold run_program. simpl.
    eapply run_host_map. eassumption.
  - reflexivity.
Qed.
