(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2016     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Pp
open Util
open Names
open Globnames
open Misctypes
open Tac2types
open Genredexpr
open Proofview
open Proofview.Notations

let return = Proofview.tclUNIT

let tactic_infer_flags with_evar = {
  Pretyping.use_typeclasses = true;
  Pretyping.solve_unification_constraints = true;
  Pretyping.use_hook = None;
  Pretyping.fail_evar = not with_evar;
  Pretyping.expand_evars = true }

(** FIXME: export a better interface in Tactics *)
let delayed_of_tactic tac env sigma =
  let _, pv = Proofview.init sigma [] in
  let c, pv, _, _ = Proofview.apply env tac pv in
  (sigma, c)

let mk_bindings = function
| ImplicitBindings l -> Misctypes.ImplicitBindings l
| ExplicitBindings l ->
  let l = List.map Loc.tag l in
  Misctypes.ExplicitBindings l
| NoBindings -> Misctypes.NoBindings

let mk_with_bindings (x, b) = (x, mk_bindings b)

let rec mk_intro_pattern = function
| IntroForthcoming b -> Loc.tag @@ Misctypes.IntroForthcoming b
| IntroNaming ipat -> Loc.tag @@ Misctypes.IntroNaming (mk_intro_pattern_naming ipat)
| IntroAction ipat -> Loc.tag @@ Misctypes.IntroAction (mk_intro_pattern_action ipat)

and mk_intro_pattern_naming = function
| IntroIdentifier id -> Misctypes.IntroIdentifier id
| IntroFresh id -> Misctypes.IntroFresh id
| IntroAnonymous -> Misctypes.IntroAnonymous

and mk_intro_pattern_action = function
| IntroWildcard -> Misctypes.IntroWildcard
| IntroOrAndPattern ipat -> Misctypes.IntroOrAndPattern (mk_or_and_intro_pattern ipat)
| IntroInjection ipats -> Misctypes.IntroInjection (List.map mk_intro_pattern ipats)
| IntroApplyOn (c, ipat) ->
  let c = Loc.tag @@ delayed_of_tactic c in
  Misctypes.IntroApplyOn (c, mk_intro_pattern ipat)
| IntroRewrite b -> Misctypes.IntroRewrite b

and mk_or_and_intro_pattern = function
| IntroOrPattern ipatss ->
  Misctypes.IntroOrPattern (List.map (fun ipat -> List.map mk_intro_pattern ipat) ipatss)
| IntroAndPattern ipats ->
  Misctypes.IntroAndPattern (List.map mk_intro_pattern ipats)

let mk_intro_patterns ipat = List.map mk_intro_pattern ipat

let intros_patterns ev ipat =
  let ipat = mk_intro_patterns ipat in
  Tactics.intro_patterns ev ipat

let apply adv ev cb cl =
  let map c =
    let c = c >>= fun c -> return (mk_with_bindings c) in
    None, Loc.tag (delayed_of_tactic c)
  in
  let cb = List.map map cb in
  match cl with
  | None -> Tactics.apply_with_delayed_bindings_gen adv ev cb
  | Some (id, cl) ->
    let cl = Option.map mk_intro_pattern cl in
    Tactics.apply_delayed_in adv ev id cb cl

let mk_destruction_arg = function
| ElimOnConstr c ->
  let c = c >>= fun c -> return (mk_with_bindings c) in
  Misctypes.ElimOnConstr (delayed_of_tactic c)
| ElimOnIdent id -> Misctypes.ElimOnIdent (Loc.tag id)
| ElimOnAnonHyp n -> Misctypes.ElimOnAnonHyp n

let mk_induction_clause (arg, eqn, as_, occ) =
  let eqn = Option.map (fun ipat -> Loc.tag @@ mk_intro_pattern_naming ipat) eqn in
  let as_ = Option.map (fun ipat -> Loc.tag @@ mk_or_and_intro_pattern ipat) as_ in
  ((None, mk_destruction_arg arg), (eqn, as_), occ)

let induction_destruct isrec ev (ic : induction_clause list) using =
  let ic = List.map mk_induction_clause ic in
  let using = Option.map mk_with_bindings using in
  Tactics.induction_destruct isrec ev (ic, using)

let elim ev c copt =
  let c = mk_with_bindings c in
  let copt = Option.map mk_with_bindings copt in
  Tactics.elim ev None c copt

let general_case_analysis ev c =
  let c = mk_with_bindings c in
  Tactics.general_case_analysis ev None c

let constructor_tac ev n i bnd =
  let bnd = mk_bindings bnd in
  Tactics.constructor_tac ev n i bnd

let left_with_bindings ev bnd =
  let bnd = mk_bindings bnd in
  Tactics.left_with_bindings ev bnd

let right_with_bindings ev bnd =
  let bnd = mk_bindings bnd in
  Tactics.right_with_bindings ev bnd

let split_with_bindings ev bnd =
  let bnd = mk_bindings bnd in
  Tactics.split_with_bindings ev [bnd]

let rewrite ev rw cl by =
  let map_rw (orient, repeat, c) =
    let c = c >>= fun c -> return (mk_with_bindings c) in
    (Option.default true orient, repeat, None, delayed_of_tactic c)
  in
  let rw = List.map map_rw rw in
  let by = Option.map (fun tac -> Tacticals.New.tclCOMPLETE tac, Equality.Naive) by in
  Equality.general_multi_rewrite ev rw cl by

let forward fst tac ipat c =
  let ipat = Option.map mk_intro_pattern ipat in
  Tactics.forward fst tac ipat c

let assert_ = function
| AssertValue (id, c) ->
  let ipat = Loc.tag @@ Misctypes.IntroNaming (Misctypes.IntroIdentifier id) in
  Tactics.forward true None (Some ipat) c
| AssertType (ipat, c, tac) ->
  let ipat = Option.map mk_intro_pattern ipat in
  Tactics.forward true (Some tac) ipat c

let letin_pat_tac ev ipat na c cl =
  let ipat = Option.map (fun (b, ipat) -> (b, Loc.tag @@ mk_intro_pattern_naming ipat)) ipat in
  Tactics.letin_pat_tac ev ipat na c cl

(** Ltac interface treats differently global references than other term
    arguments in reduction expressions. In Ltac1, this is done at parsing time.
    Instead, we parse indifferently any pattern and dispatch when the tactic is
    called. *)
let map_pattern_with_occs (pat, occ) = match pat with
| Pattern.PRef (ConstRef cst) -> (occ, Inl (EvalConstRef cst))
| Pattern.PRef (VarRef id) -> (occ, Inl (EvalVarRef id))
| _ -> (occ, Inr pat)

let get_evaluable_reference = function
| VarRef id -> Proofview.tclUNIT (EvalVarRef id)
| ConstRef cst -> Proofview.tclUNIT (EvalConstRef cst)
| r ->
  Tacticals.New.tclZEROMSG (str "Cannot coerce" ++ spc () ++
    Nametab.pr_global_env Id.Set.empty r ++ spc () ++
    str "to an evaluable reference.")

let simpl flags where cl =
  let where = Option.map map_pattern_with_occs where in
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  Tactics.reduce (Simpl (flags, where)) cl

let cbv flags cl =
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  Tactics.reduce (Cbv flags) cl

let cbn flags cl =
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  Tactics.reduce (Cbn flags) cl

let lazy_ flags cl =
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  Tactics.reduce (Lazy flags) cl

let unfold occs cl =
  let map (gr, occ) =
    get_evaluable_reference gr >>= fun gr -> Proofview.tclUNIT (occ, gr)
  in
  Proofview.Monad.List.map map occs >>= fun occs ->
  Tactics.reduce (Unfold occs) cl

let pattern where cl =
  let where = List.map (fun (c, occ) -> (occ, c)) where in
  Tactics.reduce (Pattern where) cl

let vm where cl =
  let where = Option.map map_pattern_with_occs where in
  Tactics.reduce (CbvVm where) cl

let native where cl =
  let where = Option.map map_pattern_with_occs where in
  Tactics.reduce (CbvNative where) cl

let eval_fun red c =
  Tac2core.pf_apply begin fun env sigma ->
  let (redfun, _) = Redexpr.reduction_of_red_expr env red in
  let (sigma, ans) = redfun env sigma c in
  Proofview.Unsafe.tclEVARS sigma >>= fun () ->
  Proofview.tclUNIT ans
  end

let eval_red c =
  eval_fun (Red false) c

let eval_hnf c =
  eval_fun Hnf c

let eval_simpl flags where c =
  let where = Option.map map_pattern_with_occs where in
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  eval_fun (Simpl (flags, where)) c

let eval_cbv flags c =
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  eval_fun (Cbv flags) c

let eval_cbn flags c =
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  eval_fun (Cbn flags) c

let eval_lazy flags c =
  Proofview.Monad.List.map get_evaluable_reference flags.rConst >>= fun rConst ->
  let flags = { flags with rConst } in
  eval_fun (Lazy flags) c

let eval_unfold occs c =
  let map (gr, occ) =
    get_evaluable_reference gr >>= fun gr -> Proofview.tclUNIT (occ, gr)
  in
  Proofview.Monad.List.map map occs >>= fun occs ->
  eval_fun (Unfold occs) c

let eval_fold cl c =
  eval_fun (Fold cl) c

let eval_pattern where c =
  let where = List.map (fun (pat, occ) -> (occ, pat)) where in
  eval_fun (Pattern where) c

let eval_vm where c =
  let where = Option.map map_pattern_with_occs where in
  eval_fun (CbvVm where) c

let eval_native where c =
  let where = Option.map map_pattern_with_occs where in
  eval_fun (CbvNative where) c

let on_destruction_arg tac ev arg =
  Proofview.Goal.enter begin fun gl ->
  match arg with
  | None -> tac ev None
  | Some (clear, arg) ->
    let arg = match arg with
    | ElimOnConstr c ->
      let env = Proofview.Goal.env gl in
      Proofview.tclEVARMAP >>= fun sigma ->
      c >>= fun (c, lbind) ->
      let lbind = mk_bindings lbind in
      Proofview.tclEVARMAP >>= fun sigma' ->
      let flags = tactic_infer_flags ev in
      let (sigma', c) = Unification.finish_evar_resolution ~flags env sigma' (sigma, c) in
      Proofview.tclUNIT (Some sigma', Misctypes.ElimOnConstr (c, lbind))
    | ElimOnIdent id -> Proofview.tclUNIT (None, Misctypes.ElimOnIdent (Loc.tag id))
    | ElimOnAnonHyp n -> Proofview.tclUNIT (None, Misctypes.ElimOnAnonHyp n)
    in
    arg >>= fun (sigma', arg) ->
    let arg = Some (clear, arg) in
    match sigma' with
    | None -> tac ev arg
    | Some sigma' ->
      Tacticals.New.tclWITHHOLES ev (tac ev arg) sigma'
  end

let discriminate ev arg =
  let arg = Option.map (fun arg -> None, arg) arg in
  on_destruction_arg Equality.discr_tac ev arg

let injection ev ipat arg =
  let arg = Option.map (fun arg -> None, arg) arg in
  let ipat = Option.map mk_intro_patterns ipat in
  let tac ev arg = Equality.injClause ipat ev arg in
  on_destruction_arg tac ev arg

let autorewrite ~all by ids cl =
  let conds = if all then Some Equality.AllMatches else None in
  let ids = List.map Id.to_string ids in
  match by with
  | None -> Autorewrite.auto_multi_rewrite ?conds ids cl
  | Some by -> Autorewrite.auto_multi_rewrite_with ?conds by ids cl

(** Auto *)

let trivial debug lems dbs =
  let lems = List.map delayed_of_tactic lems in
  let dbs = Option.map (fun l -> List.map Id.to_string l) dbs in
  Auto.h_trivial ~debug lems dbs

let auto debug n lems dbs =
  let lems = List.map delayed_of_tactic lems in
  let dbs = Option.map (fun l -> List.map Id.to_string l) dbs in
  Auto.h_auto ~debug n lems dbs

let new_auto debug n lems dbs =
  let make_depth n = snd (Eauto.make_dimension n None) in
  let lems = List.map delayed_of_tactic lems in
  match dbs with
  | None -> Auto.new_full_auto ~debug (make_depth n) lems
  | Some dbs ->
    let dbs = List.map Id.to_string dbs in
    Auto.new_auto ~debug (make_depth n) lems dbs

let eauto debug n p lems dbs =
  let lems = List.map delayed_of_tactic lems in
  let dbs = Option.map (fun l -> List.map Id.to_string l) dbs in
  Eauto.gen_eauto (Eauto.make_dimension n p) lems dbs

let typeclasses_eauto strategy depth dbs =
  let only_classes, dbs = match dbs with
  | None ->
    true, [Hints.typeclasses_db]
  | Some dbs ->
    let dbs = List.map Id.to_string dbs in
    false, dbs
  in
  Class_tactics.typeclasses_eauto ~only_classes ?strategy ~depth dbs

(** Inversion *)

let inversion knd arg pat ids =
  let ids = match ids with
  | None -> []
  | Some l -> l
  in
  begin match pat with
  | None -> Proofview.tclUNIT None
  | Some (IntroAction (IntroOrAndPattern p)) ->
    Proofview.tclUNIT (Some (Loc.tag @@ mk_or_and_intro_pattern p))
  | Some _ ->
    Tacticals.New.tclZEROMSG (str "Inversion only accept disjunctive patterns")
  end >>= fun pat ->
  let inversion _ arg =
    begin match arg with
    | None -> assert false
    | Some (_, Misctypes.ElimOnAnonHyp n) ->
      Inv.inv_clause knd pat ids (AnonHyp n)
    | Some (_, Misctypes.ElimOnIdent (_, id)) ->
      Inv.inv_clause knd pat ids (NamedHyp id)
    | Some (_, Misctypes.ElimOnConstr c) ->
      let open Misctypes in
      let anon = Loc.tag @@ IntroNaming IntroAnonymous in
      Tactics.specialize c (Some anon) >>= fun () ->
      Tacticals.New.onLastHypId (fun id -> Inv.inv_clause knd pat ids (NamedHyp id))
    end
  in
  on_destruction_arg inversion true (Some (None, arg))

let contradiction c =
  let c = Option.map mk_with_bindings c in
  Contradiction.contradiction c

(** Firstorder *)

let firstorder tac refs ids =
  let open Ground_plugin in
  (** FUCK YOU API *)
  let ids = List.map Id.to_string ids in
  let tac : unit API.Proofview.tactic option = Obj.magic (tac : unit Proofview.tactic option) in
  let refs : API.Globnames.global_reference list = Obj.magic (refs : Globnames.global_reference list) in
  let ids : API.Hints.hint_db_name list = Obj.magic (ids : Hints.hint_db_name list) in
  (Obj.magic (G_ground.gen_ground_tac true tac refs ids : unit API.Proofview.tactic) : unit Proofview.tactic)
