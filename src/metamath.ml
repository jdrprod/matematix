type stmt =
  (* $c *)
  | CmdC of string list
  (* $v *)
  | CmdV of string list
  (* $f *)
  | CmdF of string * string list
  (* $a *)
  | CmdA of string * string list
  (* $e *)
  | CmdE of string * string list
  (* $d *)
  | CmdD of string list
  (* $p *)
  | CmdP of string * string list * string list
  (* ${ ... $} *)
  | Block of stmt list

type prog = { name : string; content : stmt list }

let (let*) = Option.bind

module SymSet = Set.Make(String)

let keywords = SymSet.of_list [
  "$c";
  "$f";
  "$e";
  "$a";
  "$v";
  "$d";
  "$p";
  "$=";
  "$.";
  "${";
  "$}";
  "$(";
  "$)";
]

let is_keyword s = SymSet.mem s keywords

let parse inp =
  let rec parse_stmt = function
    | "${"::toks ->
      let* (l, toks) = parse_block toks in
      let* (_, toks) = expect "$}" toks in
      Some (Block l, toks)
    | "$c"::toks ->
      let* (l, toks) = parse_list toks in
      let* (_, toks) = expect "$." toks in
      Some (CmdC l, toks)
    | "$v"::toks ->
      let* (l, toks) = parse_list toks in
      let* (_, toks) = expect "$." toks in
      Some (CmdV l, toks)
    | "$d"::toks ->
      let* (l, toks) = parse_list toks in
      let* (_, toks) = expect "$." toks in
      Some (CmdD l, toks)
    | lbl::"$f"::toks when not (is_keyword lbl) ->
      let* (l, toks) = parse_list toks in
      let* (_, toks) = expect "$." toks in
      Some (CmdF (lbl, l), toks)
    | lbl::"$e"::toks when not (is_keyword lbl) ->
      let* (l, toks) = parse_list toks in
      let* (_, toks) = expect "$." toks in
      Some (CmdE (lbl, l), toks)
    | lbl::"$a"::toks when not (is_keyword lbl) ->
      let* (l, toks) = parse_list toks in
      let* (_, toks) = expect "$." toks in
      Some (CmdA (lbl, l), toks)
    | lbl::"$p"::toks when not (is_keyword lbl) ->
      let* (l, toks) = parse_list toks in
      let* (_, toks) = expect "$=" toks in
      let* (p, toks) = parse_list toks in
      let* (_, toks) = expect "$." toks in
      Some (CmdP (lbl, l, p), toks)
    | _ -> None
  and parse_list = function
    | [] -> Some ([], [])
    | x::_  as toks when is_keyword x -> Some ([], toks)
    | x::toks ->
      let* (xs, toks) = parse_list toks in
      Some (x::xs, toks)
  and parse_block toks =
    match parse_stmt toks with
    | None -> Some ([], toks)
    | Some (x, toks) ->
      let* (xs, toks) = parse_block toks in
      Some (x::xs, toks)
  and expect t = function
      | tok::toks when tok = t -> Some ((), toks)
      | _ -> None
  in
  inp
  |> Str.(split (regexp "[ \t\n]+"))
  |> parse_block

let parse_string s =
  match parse s with
  | Some (res, []) -> Some res
  | _ -> None

let parse_file f =
  let inx = open_in f in
  let s = ref "" in
  try while true do
    s := !s ^ "\n" ^ (input_line inx)
  done; assert false
  with _ ->
    Option.map
      (fun l -> { name = f; content = l })
      (parse_string !s)

type frame = {
  hypothesis : (string * string list) list;
  disjoints  : string list list
}

let empty_frame = { hypothesis = []; disjoints = [] }

let add_disj frames disj =
  match !frames with
  | f::fs -> frames := { f with disjoints = disj::f.disjoints }::fs
  | _ -> assert false

let add_hyp frames hyp =
  match !frames with
  | f::fs -> frames := { f with hypothesis = hyp::f.hypothesis }::fs
  | _ -> assert false

type statement =
  | Axm of {
    typecode : string;
    body : string list;
    frame : frame;
  }
  | Thm of {
    typecode : string;
    body : string list;
    proof : string list;
    frame : frame;
  }

type db = {
  statements : (string, statement) Hashtbl.t;
  mutable constants : SymSet.t;
  mutable variables : SymSet.t;
}

let is_var db s = SymSet.mem s db.variables

let is_cst db s = SymSet.mem s db.constants

let print_db { statements; constants; variables } =
  Printf.printf "Variables : %s\n"
    (SymSet.fold (fun x acc -> acc ^ " " ^ x) variables "");
  Printf.printf "Constants : %s\n"
    (SymSet.fold (fun x acc -> acc ^ " " ^ x) constants "");
  Printf.printf "Statements :\n";
  Hashtbl.iter (fun name -> function
    | Thm { typecode; body; frame; _ } ->
      Printf.printf "Theorem \"%s\": %s\n" name (String.concat " " (typecode::body));
      Printf.printf "Under conditions:\n";
      List.iter (fun (name, cond) ->
        Printf.printf "\t%s: %s\n" name (String.concat " " cond)
      ) frame.hypothesis
    | Axm { typecode; body; frame; _ } ->
      Printf.printf "Axiom \"%s\": %s\n" name (String.concat " " (typecode::body));
      Printf.printf "Under conditions:\n";
      List.iter (fun (name, cond) ->
        Printf.printf "\t%s: %s\n" name (String.concat " " cond)
      ) frame.hypothesis
  ) statements

let get_vars vars body =
  List.filter (fun x -> SymSet.mem x vars) body
  |> SymSet.of_list

let get_csts vars body =
  List.filter (fun x -> SymSet.mem x vars) body
  |> SymSet.of_list

let non_disj s1 s2 =
  SymSet.(not (is_empty (inter s1 s2)))

let make_frame { variables; _} frames body =
  match frames with
  | [] -> assert false
  | { hypothesis; disjoints }::_ ->
    let body_vars = get_vars variables body in
    let hypothesis =
      List.filter (fun (_, hyp) ->
        non_disj body_vars (get_vars variables hyp)
      ) hypothesis
    in
    let disjoints =
      List.filter (fun disj ->
        non_disj body_vars (get_vars variables disj)
      ) disjoints
    in
    { hypothesis; disjoints }


let check_lbl { statements; _ } lbl =
  if Hashtbl.mem statements lbl then
    Printf.eprintf "label %s already defined!\n" lbl;
    exit 1

let check_body db typecode body =
  if not (is_cst db typecode) then begin
    Printf.eprintf "A statement must start with a typecode!\n";
    exit 1
  end else begin
    let vars = get_vars db.variables body in
    let diff = SymSet.diff vars db.variables in
    if not (SymSet.is_empty diff) then begin
      Printf.eprintf "Undefined variable %s\n" (SymSet.choose diff);
      exit 1
    end
  end

let check_proof _ _ =
  failwith "not implemented yet"

let make_axm db frames body =
  match body with
  | typecode::body ->
    check_body db typecode body;
    Axm { typecode; body; frame = make_frame db frames body }
  | [] -> failwith "Unable to make empty axiom"

let make_thm db frames body proof =
  match body with
  | typecode::body ->
    check_body db typecode body;
    Thm { typecode; body; frame = make_frame db frames body; proof }
  | [] -> failwith "Unable to make empty theorem"

let make_type_hyp db frames lbl body =
  match body with
  | [ty; v] ->
    if not (is_cst db ty) then begin
      Printf.eprintf "in %s : Undefined typecode %s\n" lbl ty;
      exit 1
    end else if not (is_var db v) then begin
      Printf.eprintf "in %S : Undefined variable %s\n" lbl v;
      exit 1
    end else add_hyp frames (lbl, body)
  | _ ->
    Printf.eprintf "in %s : ill-formed typing hypothesis\n" lbl;
    exit 1

let make_hyp db frames lbl body =
  match body with
  | ty::body ->
    if not (is_cst db ty) then begin
      Printf.eprintf "in %s : Undefined typecode %s\n" lbl ty;
      exit 1
    end else begin
      add_hyp frames (lbl, body)
    end
  | _ ->
    Printf.eprintf "in %s : ill-formed hypothesis\n" lbl;
    exit 1

let make_disj db frames disj =
  if List.for_all (is_var db) disj then
    add_disj frames disj
  else
    Printf.eprintf "ill-formed disjoint-variable restriction"

let load { content; _ } : db =
  let db = { statements = Hashtbl.create 10; variables = SymSet.empty; constants = SymSet.empty } in
  let frames = ref [empty_frame] in
  let new_frame () = frames := (List.hd !frames)::!frames in
  let drop_frame () = frames := List.tl !frames in
  let rec load_block block =
    List.iter (function
      | CmdA (lbl, body) ->
        Hashtbl.add db.statements lbl (make_axm db !frames body)
      | CmdP (lbl, body, proof) ->
        Hashtbl.add db.statements lbl (make_thm db !frames body proof)
      | CmdC csts ->
        db.constants <- SymSet.union db.constants (SymSet.of_list csts)
      | CmdV vars ->
        db.variables <- SymSet.union db.variables (SymSet.of_list vars)
      | CmdF (lbl, body) ->
        make_type_hyp db frames lbl body
      | CmdE (lbl, body) ->
        make_hyp db frames lbl body
      | CmdD disj ->
        make_disj db frames disj
      | Block block ->
        new_frame ();
        load_block block;
        drop_frame ()
    ) block
  in
  load_block content;
  db

let load_file f =
  match parse_file f with
  | None -> Printf.eprintf "unable to parse file %s\n" f; exit 1
  | Some prog -> load prog |> print_db
