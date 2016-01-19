
(**************************************************************************)
(*                                                                        *)
(*                              Cubicle                                   *)
(*                                                                        *)
(*                       Copyright (C) 2011-2014                          *)
(*                                                                        *)
(*                  Sylvain Conchon and Alain Mebsout                     *)
(*                       Universite Paris-Sud 11                          *)
(*                                                                        *)
(*                                                                        *)
(*  This file is distributed under the terms of the Apache Software       *)
(*  License version 2.0                                                   *)
(*                                                                        *)
(**************************************************************************)

open Format
open Options
open Util
open Ast
open Types


module T = Smt.Term
module F = Smt.Formula

module SMT = Smt.Make (Options)

let proc_terms =
  List.iter 
    (fun x -> Smt.Symbol.declare x [] Smt.Type.type_proc) Variable.procs;
  List.map (fun x -> T.make_app x []) Variable.procs

let distinct_vars = 
  let t = Array.make max_proc F.f_true in
  let _ = 
    List.fold_left 
      (fun (acc,i) v -> 
	 if i<>0 then t.(i) <- F.make_lit F.Neq (v::acc);
	 v::acc, i+1) 
      ([],0) proc_terms 
  in
  function n -> if n = 0 then F.f_true else t.(n-1)

(* let _ = SMT.assume ~id:0 (distinct_vars max_proc) *)

let order_vars =
  let t = Array.make max_proc F.f_true in
  let _ =
    List.fold_left
      (fun (acc, lf, i) v ->
        match acc with
          | v2::r ->
            let lf = (F.make_lit F.Lt [v2;v]) :: lf in
            t.(i) <- F.make F.And lf;
            v::acc, lf, i+1
          | [] -> v::acc, lf, i+1)
      ([], [], 0) proc_terms
  in
  function n -> if n = 0 then F.f_true else t.(n-1)

let make_op_comp = function
  | Eq -> F.Eq
  | Lt -> F.Lt
  | Le -> F.Le
  | Neq -> F.Neq

let make_const = function
  | ConstInt i -> T.make_int i
  | ConstReal i -> T.make_real i
  | ConstName n -> T.make_app n []

let ty_const = function
  | ConstInt _ -> Smt.Type.type_int
  | ConstReal _ -> Smt.Type.type_real
  | ConstName n -> snd (Smt.Symbol.type_of n)

let rec mult_const tc c i =
 match i with
  | 0 -> 
    if ty_const c = Smt.Type.type_int then T.make_int (Num.Int 0)
    else T.make_real (Num.Int 0)
  | 1 -> tc
  | -1 -> T.make_arith T.Minus (mult_const tc c 0) tc
  | i when i > 0 -> T.make_arith T.Plus (mult_const tc c (i - 1)) tc
  | i when i < 0 -> T.make_arith T.Minus (mult_const tc c (i + 1)) tc
  | _ -> assert false

let make_arith_cs =
  MConst.fold 
    (fun c i acc ->
      let tc = make_const c in
      let tci = mult_const tc c i in
       T.make_arith T.Plus acc tci)

let make_cs cs =
  let c, i = MConst.choose cs in
  let t_c = make_const c in
  let r = MConst.remove c cs in
  if MConst.is_empty r then mult_const t_c c i
  else make_arith_cs r (mult_const t_c c i)
	 
let rec make_term = function
  | Elem (e, _) -> T.make_app e []
  | Const cs -> make_cs cs 
  | Access (a, li) -> T.make_app a (List.map (fun i -> T.make_app i []) li)
  | Arith (x, cs) -> 
      let tx = make_term x in
      make_arith_cs cs tx
  | Read (_, _, _) -> failwith "Prover.make_term : Read should not be in atom"
  | EventValue e -> T.make_event_val e
			       
let rec make_formula_set sa ifrm =
  F.make F.And (SAtom.fold (fun a l -> make_literal a::l) sa ifrm)

and make_literal = function
  | Atom.True -> F.f_true 
  | Atom.False -> F.f_false
  | Atom.Comp (x, op, y) ->
      let tx = make_term x in
      let ty = make_term y in
      F.make_lit (make_op_comp op) [tx; ty]
  | Atom.Ite (la, a1, a2) -> 
      let f = make_formula_set la [] in
      let a1 = make_literal a1 in
      let a2 = make_literal a2 in
      let ff1 = F.make F.Imp [f; a1] in
      let ff2 = F.make F.Imp [F.make F.Not [f]; a2] in
      F.make F.And [ff1; ff2]


let make_formula atoms ifrm =
  F.make F.And (Array.fold_left (fun l a -> make_literal a::l) ifrm atoms)

module HAA = Hashtbl.Make (ArrayAtom)

let make_formula =
  let cache = HAA.create 200001 in
  fun atoms ifrm ->
    try HAA.find cache atoms
    with Not_found ->
      let f = make_formula atoms ifrm in
      HAA.add cache atoms f;
      f

let make_formula array ifrm =
  TimeFormula.start ();
  let f = make_formula array ifrm in
  TimeFormula.pause ();
  f

let make_formula_set satom ifrm =
  TimeFormula.start ();
  let f = make_formula_set satom ifrm in
  TimeFormula.pause ();
  f


let make_disjunction nodes =
  F.make F.Or (List.map (fun a -> make_formula a []) nodes)


let make_conjuct atoms1 atoms2 =
  let l = Array.fold_left (fun l a -> make_literal a::l) [] atoms1 in
  let l = Array.fold_left (fun l a -> make_literal a::l) l atoms2 in
  F.make F.And l


let make_init_dnfs s nb_procs =
  let { init_cdnf } = Hashtbl.find s.t_init_instances nb_procs in
  List.rev_map (List.rev_map (fun a -> make_formula_set a [])) init_cdnf

let get_user_invs s nb_procs =
  let { init_invs } =  Hashtbl.find s.t_init_instances nb_procs in
  List.rev_map (fun a -> F.make F.Not [make_formula a []]) init_invs

(*
open Event

let event_of_term t c =
  match t with
  | Read (p, v, vi) ->
     let e = Event.make c p Event.ERead (v, vi) in
     EventValue e, c + 1
  | _ -> t, c

let events_of_a a c =
  match a with
  | Comp (t1, op, t2) ->
     let t1', c = event_of_term t1 c in
     let t2', c = event_of_term t2 c in
     begin match t1', t2' with
     | EventValue e1, EventValue e2 -> Comp (t1', op, t2'), e1 :: e2 :: [], c
     | EventValue e1, _ -> Comp (t1', op, t2), e1 :: [], c
     | _, EventValue e2 -> Comp (t1, op, t2'), e2 :: [], c
     | _ -> a, [], c
     end
  | _ -> a, [], c

let events_of_satom sa =
  let sa, es, c = SAtom.fold (fun a (sa, es, c) ->
    let a, el, c = events_of_a a c in
    let es = List.fold_left (fun es e ->
      let tid = Event.num_tid e in
      let tpo_f = try IntMap.find tid es.po_f with Not_found -> [] in
      let po_f = IntMap.add tid (e.uid :: tpo_f) es.po_f in
      let events = IntMap.add e.uid e es.events in
      { events; po_f }
    ) es el in
    SAtom.add a sa, es, c
  ) sa (SAtom.empty, Event.empty_struct, 1) in
  sa, es
 *)

	       
let unsafe_conj { tag = id; cube = cube; events = es; }
		nb_procs invs ievents init =
  if debug_smt then eprintf ">>> [smt] safety with: %a@." F.print init;
(**)if debug_smt then eprintf "[smt] distinct: %a@." F.print (distinct_vars nb_procs);
  SMT.clear ();
  SMT.assume ~id (distinct_vars nb_procs);
  List.iter (SMT.assume ~id) invs;

  let new_events = List.fold_left (fun events e ->
    Event.IntMap.add e.Event.uid e events
  ) es.Event.events ievents in
  let es = { es with Event.events = new_events } in

  let po = Event.gen_po es in
  let co = Event.gen_co es in
  let fence = Event.gen_fence es in
  let ifrm = List.fold_left (fun f p -> (F.make_po p) @ f) [] po in
  let ifrm = List.fold_left (fun f p -> (F.make_co p) @ f) ifrm co in
  let ifrm = List.fold_left (fun f p -> (F.make_fence p) @ f) ifrm fence in
  let el = Event.IntMap.fold (fun _ e el -> e :: el) es.Event.events [] in
  let ifrm = List.fold_left (fun f e -> (F.make_event_desc e) @ f) ifrm el in
  let ifrm = List.fold_left (fun f e -> (F.make_acyclic_rel e) @ f) ifrm el in

  let f = make_formula_set cube.Cube.litterals ifrm in
  if debug_smt then eprintf "[smt] safety: %a and %a@." F.print f F.print init;
  SMT.assume ~id init;
  SMT.assume ~events:es ~id f;
  SMT.check ()

let unsafe_dnf node nb_procs invs ievents dnf =
  try
    let uc =
      List.fold_left (fun accuc init ->
        try 
          unsafe_conj node nb_procs invs ievents init;
          raise Exit
        with Smt.Unsat uc -> List.rev_append uc accuc)
        [] dnf in
    raise (Smt.Unsat uc)
  with Exit -> ()

let unsafe_cdnf s n =
  let nb_procs = List.length (Node.variables n) in
  let cdnf_init = make_init_dnfs s nb_procs in
  let invs = get_user_invs s nb_procs in
  let ievents = s.t_ievents in
  List.iter (unsafe_dnf n nb_procs invs ievents) cdnf_init

let unsafe s n = unsafe_cdnf s n


let reached args s sa =
  SMT.clear ();
  SMT.assume ~id:0 (distinct_vars (List.length args));
  let f = make_formula_set (SAtom.union sa s) [] in
  SMT.assume ~id:0 f;
  SMT.check ()


let assume_goal_no_check { tag = id; cube = cube; events = es } =
  SMT.clear ();
  SMT.assume ~id (distinct_vars (List.length cube.Cube.vars));
  let el = Event.IntMap.fold (fun _ e el -> e :: el) es.Event.events [] in
  let ifrm = List.fold_left (fun f e -> (F.make_event_desc e) @ f) [] el in
  let f = make_formula cube.Cube.array ifrm in
  if debug_smt then eprintf "[smt] goal g: %a@." F.print f;
  SMT.assume ~events:es ~id f

let assume_node_no_check { tag = id; events = es } ap =
  let el = Event.IntMap.fold (fun _ e el -> e :: el) es.Event.events [] in
  let ifrm = List.fold_left (fun f e -> (F.make_event_desc e) @ f) [] el in
  let f = F.make F.Not [make_formula ap ifrm] in
  if debug_smt then eprintf "[smt] assume node: %a@." F.print f;
  SMT.assume ~events:es ~id f

let assume_goal n =
  assume_goal_no_check n(*;
  SMT.check  ()*) (*TSO*) (*skip call to simplify*)

let assume_node n ap =
  assume_node_no_check n ap (*;
  SMT.check () *) (*TSO*) (*skip call to simplify*)


let run ?(fp=false) () = SMT.check ~fp ()

let check_guard args sa reqs =
  SMT.clear ();
  SMT.assume ~id:0 (distinct_vars (List.length args));
  let f = make_formula_set (SAtom.union sa reqs) [] in
  SMT.assume ~id:0 f;
  SMT.check ()

let assume_goal_nodes { tag = id; cube = cube; events = es } nodes =
  SMT.clear ();
  SMT.assume ~id (distinct_vars (List.length cube.Cube.vars));
  let el = Event.IntMap.fold (fun _ e el -> e :: el) es.Event.events [] in
  let ifrm = List.fold_left (fun f e -> (F.make_event_desc e) @ f) [] el in
  let f = make_formula cube.Cube.array ifrm in
  if debug_smt then eprintf "[smt] goal g: %a@." F.print f;
  SMT.assume ~events:es ~id f;
  List.iter (fun (n, a) -> assume_node_no_check n a) nodes(*;
  SMT.check  ()*) (*TSO*) (*skip call to simplify*)
