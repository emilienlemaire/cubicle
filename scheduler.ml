open Options
open Ast
open Ast.Atom
open Format
open Random
open Num

type error = MustBeSingleNum

exception ETrue
exception EFalse
exception Inversion
exception ConstrRep

exception Error of error

let error e = raise (Error e)

type value = 
  | Var of Hstring.t
  | Numb of num
  | Hstr of Hstring.t 
  | Proc of int

type stype =
  | RGlob of Hstring.t
  | RArr of (Hstring.t * int)

type ty =
  | N (* int or real *)
  | O (* everything else *)

(* List of processes *)
let list_threads = 
  let rec lthreads l =
    function
      | n when n = nb_threads -> l
      | n -> n::(lthreads l (n+1))
  in lthreads [] 0

(* This list will contain all the transitions *)
let trans_list = ref []

(* Module to manage multi-dimensional arrays *)
module type DA = sig
    
  type 'a t
    
  type 'a dima

  val init : int -> int -> 'a -> 'a dima
  val get : 'a dima -> int list -> 'a
  val set : 'a dima -> int list -> 'a -> unit
  val print : 'a dima -> (Format.formatter -> 'a -> unit) -> unit
  val copy : 'a dima -> 'a dima
  val dim : 'a dima -> int
    
end 

module DimArray : DA = struct
    
  type 'a t = 
    | Arr of 'a array 
    | Mat of 'a t array

  type 'a dima = {dim:int; darr:'a t}

  let init d nb_elem v =
    let darr = 
      let rec init' d nb_elem v =
	match d with
	  | 1 -> Arr (Array.init nb_elem (fun _ -> v))
	  | n -> Mat (Array.init nb_elem (fun _ -> (init' (n-1) nb_elem v)))
      in init' d nb_elem v
    in {dim=d; darr=darr}

  let get t ind = 
    let rec get' t ind =
      match t, ind with 
	| Arr a, [i] -> a.(i) 
	| Mat m, hd::tl -> let t = m.(hd) in get' t tl 
	| _ -> failwith "DimArray.get : Index error"
    in get' t.darr ind

  let set t ind v =
    let rec set' t ind =
      match t, ind with
	| Arr a, [i] -> a.(i) <- v
	| Mat m, hd::tl -> let t = m.(hd) in set' t tl
	| _ -> failwith "DimArray.set : Index error"
    in set' t.darr ind

  let print t f =
    let rec print' t =
      match t with
	| Arr a -> printf "[| ";
	  Array.iter (fun e -> printf "%a " f e) a;
	  printf "|]"
	| Mat m -> printf "[| ";
	  Array.iter (fun a -> print' a) m;
	  printf "|]"
    in print' t.darr

  let copy t =
    let rec copy' t =
      match t with
	| Arr a -> Arr (Array.copy a)
	| Mat m -> Mat (Array.map (fun a -> copy' a) m)
    in {dim = t.dim; darr = copy' t.darr}

  let dim t = t.dim

end

module type St = sig

  (* A dimensional array *)
  type 'a da
  (* The state : global variables and arrays *)
  type 'a t = {globs :(Hstring.t, 'a) Hashtbl.t; arrs : (Hstring.t, 'a da) Hashtbl.t}
      
  val init : unit -> 'a t
    
  val equal : 'a t -> 'a t -> bool
  val hash : 'a t -> int
    
  (* Get a global variable value *)
  val get_v : 'a t -> Hstring.t -> 'a
  (* Get an array by its name *)
  val get_a : 'a t -> Hstring.t -> 'a da
  (* Get an element in an array by its name and a a param list*)
  val get_e : 'a t -> Hstring.t -> int list -> 'a
    
  (* Set a global variable value *)
  val set_v : 'a t -> Hstring.t -> 'a -> unit
  (* Set an array by its name and a new array *)
  val set_a : 'a t -> Hstring.t -> 'a da -> unit
  (* Set an element in an array by its name, a param list and a value *)
  val set_e : 'a t -> Hstring.t -> int list -> 'a -> unit
    
  val copy : 'a t -> 'a t
    
end

module State ( A : DA ) : St with type 'a da = 'a A.dima = struct
    
  type 'a t = {globs: (Hstring.t, 'a) Hashtbl.t; arrs: (Hstring.t, 'a A.dima) Hashtbl.t}
  type 'a da = 'a A.dima

  let init () = {globs = Hashtbl.create 17; arrs = Hashtbl.create 17}

  let equal s1 s2 =
    try
      let gs1 = s1.globs in
      let gs2 = s2.globs in
      Hashtbl.iter (
	fun g v1 -> let v2 = Hashtbl.find gs2 g in
		    if v1 <> v2 then raise Exit
      ) gs1;
      true
    with
	Exit -> false

  let hash = Hashtbl.hash

  let get_v t h = Hashtbl.find t.globs h
  let get_a t h = Hashtbl.find t.arrs h
  let get_e t h pl = let arr = get_a t h in
		     A.get arr pl

  let set_v t h v = Hashtbl.replace t.globs h v
  let set_a t h arr = Hashtbl.replace t.arrs h arr
  let set_e t h pl v = let arr = get_a t h in
		       A.set arr pl v

  let copy t = let carrs = Hashtbl.copy t.arrs in
	       Hashtbl.iter (fun name arr -> Hashtbl.replace carrs name (A.copy arr)) carrs;
	       {globs = Hashtbl.copy t.globs; arrs = carrs}

end


module type Sys = sig

  (* A state *)
  type 'a s
  (* A dimensional array *)
  type 'a da
  type 'a set
  (* A record with a readable state and a writable state *)
  type 'a t = {syst : 'a set; read_st : 'a s; write_st : 'a s}

  val init : unit -> 'a t

  val get_v : 'a t -> Hstring.t -> 'a
  val get_a : 'a t -> Hstring.t -> 'a da
  val get_e : 'a t -> Hstring.t -> int list -> 'a

  val set_v : 'a t -> Hstring.t -> 'a -> unit
  val set_a : 'a t -> Hstring.t -> 'a da -> unit
  val set_e : 'a t -> Hstring.t -> int list -> 'a -> unit

  val exists : ('a s -> bool) -> 'a set -> bool

  val update_s : Hstring.t -> 'a t -> 'a t
    
end

module System ( S : St ) : Sys 
  with type 'a da = 'a S.da and type 'a s = 'a S.t and type 'a set = (Hstring.t * 'a S.t) list = struct

    type 'a da = 'a S.da
    type 'a s = 'a S.t
    type 'a set = (Hstring.t * 'a S.t) list
    type 'a t = {syst : (Hstring.t *'a S.t) list; read_st : 'a S.t; write_st : 'a S.t}
	
    let init () = {syst = []; read_st = S.init (); write_st = S.init ()}

    let get_v s h = let state = s.read_st in
		    S.get_v state h
    let get_a s h = let state = s.read_st in
  		    S.get_a state h
    let get_e s h pl = let state = s.read_st in
  		       S.get_e state h pl

    let set_v s h v = let state = s.write_st in
  		      S.set_v state h v
    let set_a s h a = let state = s.write_st in
  		      S.set_a state h a
    let set_e s h pl v = let state = s.write_st in
  			 S.set_e state h pl v

    let exists f s = List.exists (fun (_, e) -> f e) s

    let update_s tr s = {syst = (tr, S.copy s.write_st) :: s.syst; read_st = s.write_st; write_st = s.write_st}

  end
				  

(* GLOBAL VARIABLES *)

module Etat = State (DimArray)
module Syst = System (Etat)

let system = ref (Syst.init ())

(* Types *)
let htbl_types = Hashtbl.create 11

(* Filling htbl_types with default types (proc, bool, int and real) *)
let () = 
  List.iter (
    fun (constr, fields) -> 
      Hashtbl.add htbl_types constr fields
  ) [ Hstring.make "proc", List.map (fun i -> Proc i) list_threads;
      Hstring.make "bool", [Hstr Ast.hfalse; Hstr Ast.htrue];
      Hstring.make "int", [Numb (Int 0)];
      Hstring.make "real", [Numb (Int 0)]
    ]

let compare_value v1 v2 = 
  match v1, v2 with
    | Numb n1, Numb n2 -> Num.compare_num n1 n2
    | Hstr h1, Hstr h2 
    | Var h1, Var h2 -> Hstring.compare h1 h2
    | Proc p1, Proc p2 -> Pervasives.compare p1 p2
    | _ -> assert false

module TS = Set.Make (struct type t = value let compare = compare_value end)
module TI = Set.Make (struct type t = Hstring.t let compare = Hstring.compare end)

(* This hashtbl contains variables binded to their representant
   and their type *)
let ec = Hashtbl.create 17
(* This hashtbl contains variables binded to :
   - int or real : the list of their forbiddent values
   - rest : the list of their possible values
   and the list of the representants with which they differ *)
let dc = Hashtbl.create 17


(* USEFUL METHODS *)


(* Tranform a constant in a num *)
let value_c c =
  match MConst.is_num c with
    | Some e -> e
    | None -> error (MustBeSingleNum)

(* Return the operator on int (for proc) *)
let find_op =
  function
    | Eq -> (=)
    | Lt -> (<)
    | Le -> (<=)
    | Neq -> (<>)

(* Return the operator on Num.num (for int and real) *)
let find_nop =
  function
    | Eq -> (=/)
    | Lt -> (</)
    | Le -> (<=/)
    | Neq -> (<>/)

(* Return the first type constructor *)
let default_type g_type =
  match Hashtbl.find htbl_types g_type with
    | [] -> Hstr g_type
    | hd::_ -> hd

(* Intersection of two int lists *)
let inter l1 l2s =
  let l1s = List.sort Pervasives.compare l1 in
  (* l2s is already sorted *)
  let rec inter' l1 l2 =
    match l1, l2 with
      | [], _ -> l2
      | _, [] -> l1
      | hd1::tl1, hd2::tl2 when hd1 = hd2 -> inter' tl1 tl2
      | hd1::tl1, hd2::_ when hd1 < hd2 -> let l' = inter' tl1 l2 in
					   hd1::l'
      | _, hd2::tl2 -> let l' = inter' l1 tl2 in
		       hd2::l'
  in inter' l1s l2s

(* Return the name of the representant (Hstring.t) *)
let rep_name n =
  let (rep, _) = Hashtbl.find ec n in
  match rep with
    | Var id -> id
    | _ -> raise ConstrRep

let hst_var =
  function
    | Var h -> h
    | _ -> assert false

(* VALUE METHODS *)

(* Return a constant value *)
let get_cvalue =
  function
    | Const c -> Numb (value_c c)
    | Elem (id, Constr) -> Hstr id
    | _ -> assert false

(* Return a constant value or the value of a variable
   (global or array) *)
let get_value sub =
  function
    | (Const _ as v) | (Elem (_, Constr) as v) -> get_cvalue v
    | Elem (id, Glob) -> Syst.get_v !system id
    | Elem (id, _) -> let (_, i) = 
			List.find (fun (e, _) -> Hstring.equal e id) sub 
		      in Proc i
    | Access (id, pl) -> 
      let ind = List.map (
	fun p -> 
	  let (_, i) = List.find (
	    fun (p', _) -> p = p'
	  ) sub in i
      ) pl in
      Syst.get_e !system id ind
    | _ -> assert false

let print_value f v =
  match v with
    | Numb i -> printf "%s " (Num.string_of_num i)
    | Proc p -> printf "%d " p
    | Hstr h | Var h -> printf "%a " Hstring.print h

let v_equal v1 v2 =
  match v1, v2 with
    | Var h1, Var h2
    | Hstr h1, Hstr h2 -> Hstring.equal h1 h2
    | Numb i1, Numb i2 -> i1 =/ i2
    | Proc p1, Proc p2 -> p1 == p2
    | _ -> false



(* INITIALIZATION METHODS *)


(* Each type is associated to his constructors 
   The first one is considered as the default type *)
let init_types type_defs =
  List.iter (
    fun (t_name, t_fields) ->
      let fields = List.fold_right (
	fun field acc -> (Hstr field)::acc
      ) t_fields [] in
      Hashtbl.add htbl_types t_name fields
  ) type_defs

(* Initialization of the global variables to their
   default constructor, of the equivalence classes and
   of the difference classes *)
let init_globals globals =
  let i = Hstring.make "int" in
  let r = Hstring.make "real" in
  List.iter (
    fun (g_name, g_type) ->
      (* Here is the deterministic initialization *)
      let default_type = default_type g_type in
      Syst.set_v !system g_name default_type;
      (* End of the deterministic initialization *)
      (* First, each var is its own representant *)
      Hashtbl.add ec g_name (Var g_name, RGlob g_type);
      let ty, stypes = 
	if (Hstring.equal g_type i || Hstring.equal g_type r) 
	(* Int or real*)
	then N, TS.empty
	(* Other type*)
	else 
	  let ty = Hashtbl.find htbl_types g_type in
	  let st = List.fold_left (fun acc t -> TS.add t acc) TS.empty ty in
	  O, st
      in
      Hashtbl.add dc g_name (ty, stypes, TI.empty)
  ) globals

(* Initialization of the arrays with their default
   constructor (deterministic version) of the equivalence classes and
   of the difference classes *)
let init_arrays arrays =
  let i = Hstring.make "int" in
  let r = Hstring.make "real" in
  List.iter (
    fun (a_name, (a_dims, a_type)) ->
      let dims = List.length a_dims in
      (* Here is the deterministic initialization *)
      let default_type = default_type a_type in
      let new_t = DimArray.init dims nb_threads default_type in
      Syst.set_a !system a_name new_t;
      (* End of the deterministic initialization *)
      Hashtbl.add ec a_name (Var a_name, RArr (a_type, dims));
      let ty, stypes = 
	if (Hstring.equal a_type i || Hstring.equal a_type r) 
	(* Int or real *)
	then N, TS.empty 
	(* Other type *)
	else
	  let ty = Hashtbl.find htbl_types a_type in
	  let st = List.fold_left (fun acc t -> TS.add t acc) TS.empty ty in
	  O, st
      in
      Hashtbl.add dc a_name (ty, stypes, TI.empty)
  ) arrays
    
(* Execution of the real init method from the cubicle file 
   to initialize the equivalence classes and difference classes *)
let init_htbls (vars, atoms) =
  List.iter (
    fun satom ->
      SAtom.iter (
	fun atom ->
	  match atom with
	    | Comp (t1, Eq, t2) ->
	      begin
		match t1, t2 with
		  (* Var = Const or Const = Var *)
		  | (Elem (id1, Glob) | Access (id1, _)), ((Elem (_, Constr) | Const _) as r) 
		  | ((Elem (_, Constr) | Const _) as r), (Elem (id1, Glob) | Access (id1, _)) ->
	    	    let (rep, _) = Hashtbl.find ec id1 in
		    let h = hst_var rep in
		    let v = get_cvalue r in
		    (* Change the representant of the equivalence class with the constant. 
		       Remove the equivalence class from the difference classes hashtbl *)
		    Hashtbl.iter ( 
		      fun n (rep', tself) ->
			if (rep' == rep)
			then
			  (
			    Hashtbl.remove dc n;
			    Hashtbl.replace ec n (v, tself)
			  )
		    ) ec;
		    (* Change the difference classes so the representant 
		       is now an impossible value *)
		    Hashtbl.iter (
		      fun n (ty, types, diffs) ->
			if (TI.mem h diffs)
			then let diffs' = TI.remove h diffs in
			     let types' = TS.remove v types in
			     Hashtbl.replace dc n (ty, types', diffs')
		    ) dc
		      
		  (* Var or Tab[] = Var or Tab[] *)
		  | (Elem (id1, Glob) | Access (id1, _)), (Elem (id2, Glob) | Access (id2, _)) ->
		    let (rep, _) as t1 = Hashtbl.find ec id1 in
		    let t2 = Hashtbl.find ec id2 in
		    let ids, idd, (sr, _), (dr, dts) = 
		      match rep with
			| Var _ -> id2, id1, t2, t1
			| _ -> id1, id2, t1, t2 
		    in
		    (match sr with
		      (* If the future representant is not a constant,
			 modify the difference class of the representant. *)
		      | Var _ -> let (ty1, types1, diffs1) = Hashtbl.find dc ids in
				 let (ty2, types2, diffs2) = Hashtbl.find dc idd in
				 let types = 
				   match ty1 with
				     | N -> TS.union types1 types2
				     | O -> TS.inter types1 types2
				 in 
				 let diffs = TI.union diffs1 diffs2 in 
				 Hashtbl.replace dc ids (ty1, types, diffs)
		      | _ -> ()
		    );
		    (* Remove the non-chosen variable from the difference classes hashtbl *)
		    Hashtbl.remove dc idd;
		    (* Modify the representant of each variable which representant was the 
		       non-chosen variable *)
		    Hashtbl.iter (
		      fun n (rep', tself) ->
			if (rep' == dr)
			then 
			  Hashtbl.replace ec n (sr, tself)
		    ) ec		    		 
		  | _ -> assert false
	      end
	    | Comp (t1, Neq, t2) ->
	      begin
	    	match t1, t2 with
		  (* Var or Tab[] <> Const or Const <> Var or Tab[] *)
	    	  | (Elem (id1, Glob) | Access (id1, _)), ((Elem (_, Constr) | Const _) as c) 
		  | ((Elem (_, Constr) | Const _) as c), (Elem (id1, Glob) | Access (id1, _)) ->
		    (* Delete the constr from the possible values of the variable representant *)
		    begin
		      try
			let h = rep_name id1 in
	    		let (ty, types, diffs) = Hashtbl.find dc h in
	    		let v = get_cvalue c in
			let types' = match ty with
			  | N -> TS.add v types
			  | O -> TS.remove v types 
			in
	    		Hashtbl.replace dc h (ty, types', diffs)
		      with ConstrRep -> () (* Strange but allowed *)
		    end
		  (* Var or Tab[] <> Var or Tab[] *)
	    	  | (Elem (id1, Glob) | Access (id1, _)), (Elem (id2, Glob) | Access (id2, _)) ->
	    	    begin
		      let (rep1, tself1) = Hashtbl.find ec id1 in
		      let (rep2, tself2) = Hashtbl.find ec id2 in
		      match rep1, rep2 with
			| Var h1, Var h2 -> let (ty1, types1, diffs1) = Hashtbl.find dc h1 in
	    				    let (ty2, types2, diffs2) = Hashtbl.find dc h2 in
	    				    Hashtbl.replace dc h1 (ty1, types1, TI.add h2 diffs1);
	    				    Hashtbl.replace dc h2 (ty2, types2, TI.add h1 diffs2)
	    		| Var h, (_ as rep') 
			| (_ as rep'), Var h -> 	
		  let (ty, types, diffs) = Hashtbl.find dc h in
			  let types' = match ty with
			    | N -> TS.add rep' types
			    | O -> TS.remove rep' types
			  in
			  Hashtbl.replace dc h (ty, types', diffs)
			| _ -> () (* Strange but that's your problem *)
		    end
		  | Elem (id, Glob), Elem (_, Var)
		  | Elem (_, Var), Elem (id, Glob) ->
		    let h = rep_name id in
		    let (ty, _, diffs) = Hashtbl.find dc h in
		    Hashtbl.replace dc h (ty, TS.empty, diffs)
		  | _ -> assert false
	      end
	    | _ -> assert false
      ) satom
  ) atoms

let c = ref 0
let groups = Hashtbl.create 17

let update () =  
  Hashtbl.iter (
    fun n (_, types, diffs) ->
      if TS.cardinal types == 1
      then
	(
	  Hashtbl.remove dc n;
	  let v = TS.choose types in
	  Hashtbl.iter (
	    fun n' (rep, tself) ->
	      match rep with
		| Var h -> if (h == n)
		  then Hashtbl.replace ec n' (v, tself)
		| _ -> ()
	  ) ec;
	  Hashtbl.iter (
	    fun n' (ty, types, diffs) ->
	      if (TI.mem n diffs)
	      then let diffs' = TI.remove n diffs in
		   let types' = TS.remove v types in
		   Hashtbl.replace dc n' (ty, types', diffs')
	  ) dc
	)
      else if TI.cardinal diffs > 0
      then
	()
	
  ) dc

let g = Hashtbl.create 17


let comp_node (h1, (_, ty1, di1)) (h2, (_, ty2, di2)) =
  let ct1 = TS.cardinal ty1 in
  let ct2 = TS.cardinal ty2 in
  if ct1 < ct2
  then -1
  else 
    (
      if ct1 > ct2
      then 1
      else (
	let cd1 = TI.cardinal di1 in
	let cd2 = TI.cardinal di2 in
	if cd1 > cd2
	then 1
	else 
	  if cd1 < cd2 then -1
	  else 0
      )
    )

let graphs () =
  let dc' = Hashtbl.copy dc in
  Hashtbl.iter (
    fun n ((ty, types, diffs) as b) ->
      let list =
	TI.fold (
	  fun e l -> 
	    let elt = Hashtbl.find dc e in
	    (* Hashtbl.remove dc e; *)
	    (e, elt)::l
	) diffs [] in
      TI.iter (
	fun e ->
	  Hashtbl.remove dc' e
      ) diffs;
      let slist = List.sort comp_node ((n,b)::list) in
      Hashtbl.add g !c slist;
      Hashtbl.remove dc' n;
      incr c  
  ) dc'  

let print_ce_diffs () =
  printf "\nce :@.";
  Hashtbl.iter (
    fun n (rep, tself) ->
      printf "%a : " Hstring.print n;
      print_value printf rep;
      printf "@.";
  ) ec;
  printf "\nDc@.";
  Hashtbl.iter (
    fun n (ty, types, diffs) ->
      printf "%a : " Hstring.print n;
      TS.iter (print_value printf) types;
      TI.iter (printf "%a " Hstring.print) diffs;
      printf "@."
  ) dc;
  printf "@."

let print_g () =
  Hashtbl.iter (
    fun c l ->
      printf "%d :@." c;
      List.iter (
	fun (n, (ty, types, diffs)) ->
	  printf "%a : " Hstring.print n;
	  TS.iter (print_value printf) types;
	  TI.iter (printf "%a " Hstring.print) diffs;
	  printf "@."
      ) l;
  ) g;
  printf "@."

let initialization init =
  init_htbls init;
  
  update ();
  graphs ();
  print_ce_diffs ();
  print_g ();
  Hashtbl.iter (
    fun n (rep, tself) ->
      let value =
	match rep, tself with
	  | Var _, (RGlob t | RArr (t, _)) -> default_type t
	  | _ as v, _ -> v
      in
      match tself with
	(* Init global variables *)
	| RGlob _ -> Syst.set_v !system n value
	(* Init arrays *)
	| RArr (_, d) -> let tbl = DimArray.init d nb_threads value in
			 Syst.set_a !system n tbl
  ) ec;
  system := Syst.update_s (Hstring.make "init") !system


(* SUBSTITUTION METHODS *)

    
(* Here, optimization needed if constant values *)     
let subst_req sub req =
  let f = fun () ->
    match req with
      | True -> raise ETrue
      | False -> raise EFalse
      | Comp (t1, op, t2) -> 
	let t1_v = get_value sub t1 in
	let t2_v = get_value sub t2 in
	begin 
	  match t1_v, t2_v with
	    | Numb n1, Numb n2 ->
	      let op' = find_nop op in
	      op' n1 n2
	    | Proc p1, Proc p2 -> 
	      let op' = find_op op in
	      op' p1 p2
	    | Hstr h1, Hstr h2 ->
	      begin
		match op with
		  | Eq -> Hstring.equal h1 h2
		  | Neq -> not (Hstring.equal h1 h2)
		  | _ -> assert false
	      end
	    (* Problem with ref_count.cub, assertion failure *)
	    | Hstr h, Proc i1 -> let (p, _) = List.find (fun (_, i) -> i1 = i) sub in 
				 printf "TODO %a, %a = %d@." Hstring.print h Hstring.print p i1; 
				 exit 1
	    | _ -> assert false
	end
      | _ -> assert false
  in f

(* Type : (unit -> bool) list list list
   ____ (fun () -> bool) conj disj conj *)
let subst_ureq subst subsm ureq =
  List.fold_left (
    (* Conjonction of forall_other z -> SAtom List *)
    fun conj_acc (k, sa_lst_ureq) ->
      let subst_satom =
	List.fold_left (
	  (* Disjonction of SAtom *)
	  fun disj_acc sa_ureq ->
	    let subst_satom_list =
	      SAtom.fold (
		(* Conjonction of Atom *)
		fun ureq conj_acc' ->
		  let subst_atom =
		    List.fold_left (
		      (* Conjonction of substitute Atom *)
		      fun subst_atom s ->
			let sub = (k, s) in
			(subst_req (sub::subst) ureq)::subst_atom
		    ) [] subsm
		  in subst_atom @ conj_acc'
	      ) sa_ureq []
	    in subst_satom_list :: disj_acc
	) [] sa_lst_ureq
      in subst_satom :: conj_acc
  ) [] ureq 

let substitute_req sub reqs =
  (* Existential requires management *)
  SAtom.fold (
    fun req acc ->
      try
	let subst_req = subst_req sub req in
	subst_req::acc
      with ETrue -> acc
  ) reqs [] 

let substitute_updts sub assigns upds =
  let subst_assigns = List.fold_left (
    fun acc (var, assign) -> 
      (fun () -> let value = get_value sub assign in
		 Syst.set_v !system var value)::acc
  ) [] assigns in
  let subst_upds = List.fold_left (
    fun tab_acc u -> 
      let arr = Syst.get_a !system u.up_arr in
      let arg = u.up_arg in
      let subs = Ast.all_permutations arg list_threads in
      let upd_tab =
	List.fold_left (
	  fun upd_acc spl ->
	    let s = spl@sub in
	    let (_, pl) = List.split spl in
	    let supd =
	      List.fold_right (
		fun (conds, term) disj_acc ->
		  let filter =
		    SAtom.fold (
		      fun cond conj_acc -> (subst_req s cond)::conj_acc
		    ) conds [] in 
		  let f = fun () ->
		    let t = get_value s term in
		    DimArray.set arr pl t;
		    Syst.set_a !system u.up_arr arr
		  in
		  (filter, f)::disj_acc
	      ) u.up_swts []
	    in supd::upd_acc
	) [] subs
      in upd_tab::tab_acc
  ) [] upds in
  (subst_assigns, subst_upds)
    

(* SYSTEM INIT *)

let init_system se =
  init_types se.type_defs;
  (* This part may change, deterministic for now *)
  init_arrays se.arrays;
  init_globals se.globals;
  (* --- After this, all the variables and arrays are initialized --- *)
  initialization se.init

let init_transitions trans =
  trans_list := List.fold_left (
    fun acc tr ->
      (* Associate the processes to numbers (unique) *)
      let subs = 
	if List.length tr.tr_args > nb_threads 
	then [] (* Should not occure *)
	else Ast.all_permutations tr.tr_args list_threads
      in
      List.fold_left (
	fun acc' sub -> 
	  try 
	    let (_, pl) = List.split sub in
	    let subsm = inter pl list_threads in
	    let subst_ureq = subst_ureq sub subsm tr.tr_ureq in
	    let subst_guard = substitute_req sub tr.tr_reqs in
	    let subst_updates = substitute_updts sub tr.tr_assigns tr.tr_upds in
	    let tr_name = ref (Hstring.view tr.tr_name) in
	    List.iter (fun (id, i) -> let si = string_of_int i in
				      tr_name := !tr_name ^ " " ^ (Hstring.view id) ^ si;) sub;
	    (Hstring.make !tr_name, subst_guard, subst_ureq, subst_updates)::acc'
	  with EFalse -> acc'
      ) acc subs
  ) [] trans



(* SCHEDULING *)


let valid_req req =
  List.for_all (fun e -> e ()) req

let valid_ureq ureq = 
  List.for_all (
    fun for_all_other ->
      List.exists (
	fun s_atom_funs_list ->
	  List.for_all (
	    fun s_atom_funs -> s_atom_funs ()
	  ) s_atom_funs_list
      ) for_all_other
  ) ureq

let valid_upd arrs_upd =
  List.fold_left (
    fun arr_acc arr_upds ->
      let arrs_u = 
	List.fold_left (
	  fun acc elem ->
	    let (_, upd) = List.find (
	      fun (cond, _) -> List.for_all (fun c -> c ()
	      ) cond
	    ) elem in
	    upd::acc
	) [] arr_upds
      in arrs_u::arr_acc
  ) [] arrs_upd

let valid_trans_list () =
  let trans_list = !trans_list in
  List.fold_left (
    fun updts_l (name, req, ureq, updts) ->
      if valid_req req && valid_ureq ureq then (name, updts)::updts_l
      else updts_l
  ) [] trans_list

let random_transition () =
  let valid_trans = valid_trans_list () in
  let n = Random.int (List.length valid_trans) in
  let (name, updts) = List.nth valid_trans n in
  (name, updts)



(* SYSTEM UPDATE *)


let print_system (tr, {Etat.globs; Etat.arrs}) =
  printf "@.";
  printf "%a@." Hstring.print tr;
  Hashtbl.iter (
    fun var value ->
      printf "%a -> " Hstring.print var;
      match value with
	| Numb n -> printf "%s@." (string_of_num n)
  	| Proc p -> printf "%d@." p
  	| Hstr h | Var h -> printf "%a@." Hstring.print h
  ) globs;
  Hashtbl.iter (
    fun name tbl -> printf "%a " Hstring.print name;
      DimArray.print tbl print_value;
      printf "@."
  ) arrs;
  printf "@."

let update_system () =
  let (tr, (assigns, updates)) = random_transition () in
  (* print_system (tr, !system.Syst.read_st); *)
  List.iter (fun a -> a ()) assigns;
  let updts = valid_upd updates in 
  List.iter (fun us -> List.iter (fun u -> u ()) us ) updts;
  (* print_system (tr, !system.Syst.read_st); *)
  system := Syst.update_s tr !system
    
(* INTERFACE WITH BRAB *)

let get_value_st sub st =
  function
    | Const c -> Numb (value_c c)
    | Elem (id, Glob) -> Etat.get_v st id
    | Elem (id, Constr) -> Hstr id
    | Elem (id, _) -> let (_, i) =
			List.find (fun (e, _) -> Hstring.equal e id) sub
		      in Proc i
    | Access (id, pl) ->
      let ind = List.map (
	fun p ->
	  let (_, i) = List.find (
	    fun (p', _) -> p = p'
	  ) sub in i
      ) pl in
      Etat.get_e st id ind
    | _ -> assert false

let contains sub sa s =
  Syst.exists (
    fun state ->
      SAtom.for_all (
	fun a ->
	  match a with
	    | True -> true
	    | False -> false
	    | Comp (t1, op, t2) -> 
	      let t1_v = get_value_st sub state t1 in
	      let t2_v = get_value_st sub state t2 in
	      begin
		match t1_v, t2_v with
		  | Numb n1, Numb n2 ->
		    let op' = find_nop op in
		    op' n1 n2
		  | Proc p1, Proc p2 -> 
		    let op' = find_op op in
		    op' p1 p2
		  | Hstr h1, Hstr h2 ->
		    begin
		      match op with
			| Eq -> Hstring.equal h1 h2
			| Neq -> not (Hstring.equal h1 h2)
			| _ -> assert false
		    end
		  (* Problem with ref_count.cub, assertion failure *)
		  | _ -> assert false
	      end
	    | _ -> assert false
      ) sa
  ) !system.Syst.syst
    
let filter t_syst_l =
  try
    let rcube = List.find (
      fun t_syst -> let (pl, sa) = t_syst.t_unsafe in
		    let subst = Ast.all_permutations pl list_threads in
		    List.for_all (
		      fun sub ->
			not (contains sub sa !system)
		    ) subst
    ) t_syst_l in
    Some rcube
  with Not_found -> None

(* MAIN *)

    
let scheduler se =
  Random.self_init ();
  init_system se;
  init_transitions se.trans;
  let count = ref 1 in
  while !count < nb_exec do
    update_system ();
    incr count
  done;
  if verbose > 0 then
    begin
      let count = ref 1 in
      List.iter (
	fun st -> printf "%d : " !count; incr count; print_system st
      ) (List.rev !system.Syst.syst)
    end;
  printf "Scheduled %d states\n" !count;
  printf "--------------------------@."

let dummy_system = {
  globals = [];
  consts = [];
  arrays = [];
  type_defs = [];
  init = [],[];
  invs = [];
  cands = [];
  unsafe = [];
  forward = [];
  trans = [];
}


let current_system = ref dummy_system

let register_system s = current_system := s

let run () =
  assert (!current_system <> dummy_system);
  scheduler !current_system
