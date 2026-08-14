(* hip_print — MiniHIP.json -> .hip printer (G4).
   Unverified shell (reviewed, structurally tested): reprints the mapped AST
   as HIP source. Kernel bodies print 1:1; launches become hipLaunchKernelGGL;
   host_code (incl. #includes, hoisted to the top) passes through verbatim.

   Known v1 limitation: EFloat literals print with %g plus a ".0" suffix when
   integral-looking; the f-suffix/double distinction is not tracked in
   schema v1 (no kernel float literals in the v1 corpus).

   Usage: hip_print <in.minihip.json> -o <out.hip>
   Exit: 0 ok | 3 contract/IO error. *)

open Cu2hip_core.Mini_json
open Extracted.MiniCuda

let buf = Buffer.create 4096
let emit s = Buffer.add_string buf s

let rec render_expr = function
  | EVar x -> str_of_cl x
  | EInt z -> string_of_int z
  | EFloat f -> (
      let s = Printf.sprintf "%g" (Float64.to_float f) in
      if String.contains s '.' || String.contains s 'e' || String.contains s 'n'
         || String.contains s 'i' then
        s
      else s ^ ".0")
  | EBinop (op, l, r) ->
      "(" ^ render_expr l ^ " " ^ string_of_binop op ^ " " ^ render_expr r ^ ")"
  | EUnop (op, e) -> "(" ^ string_of_unop op ^ render_expr e ^ ")"
  | ESubscript (b, i) -> render_expr b ^ "[" ^ render_expr i ^ "]"
  | EBuiltin b -> string_of_builtin b
  | EAddrof x -> "&" ^ str_of_cl x
  | ECall (f, args) -> str_of_cl f ^ "(" ^ String.concat ", " (List.map render_expr args) ^ ")"

let render_ty = function
  | TyInt -> "int"
  | TyFloat -> "float"
  | TyDouble -> "double"

let rec render_stmt indent = function
  | SLet (x, t, e) ->
      indent ^ render_ty t ^ " " ^ str_of_cl x ^ " = " ^ render_expr e ^ ";\n"
  | SStore (t, v) -> indent ^ render_expr t ^ " = " ^ render_expr v ^ ";\n"
  | SIf (c, th, el) ->
      let s =
        indent ^ "if (" ^ render_expr c ^ ") {\n"
        ^ String.concat "" (List.map (render_stmt (indent ^ "  ")) th)
        ^ indent ^ "}"
      in
      if el = [] then s ^ "\n"
      else
        s ^ " else {\n"
        ^ String.concat "" (List.map (render_stmt (indent ^ "  ")) el)
        ^ indent ^ "}\n"
  | SSync -> indent ^ "__syncthreads();\n"
  | SExpr e -> indent ^ render_expr e ^ ";\n"

let render_param p =
  render_ty p.pty ^ " " ^ (if p.pptr then "*" else "") ^ str_of_cl p.pname

let render_kernel k =
  "__global__ void " ^ str_of_cl k.kname ^ "("
  ^ String.concat ", " (List.map render_param k.kparams)
  ^ ") {\n"
  ^ String.concat ""
      (List.map
         (fun s ->
           "  __shared__ " ^ render_ty s.sty ^ " " ^ str_of_cl s.sname ^ "["
           ^ string_of_int s.ssize ^ "];\n")
         k.kshared)
  ^ String.concat "" (List.map (render_stmt "  ") k.kbody)
  ^ "}\n"

let memcpy_kind = function
  | CK_H2D -> "hipMemcpyHostToDevice"
  | CK_D2H -> "hipMemcpyDeviceToHost"
  | CK_D2D -> "hipMemcpyDeviceToDevice"
  | CK_H2H -> "hipMemcpyHostToHost"

let is_include t =
  let t = String.trim t in
  String.length t >= 8 && String.sub t 0 8 = "#include"

(* Host nodes: #includes hoisted to file top; everything else into main(). *)
let render_host_node = function
  | HApi (f, args, ck) ->
      let args =
        match (str_of_cl f, ck) with
        | ("hipMemcpy", Some k) ->
            List.map render_expr args @ [ memcpy_kind k ]
        | _ -> List.map render_expr args
      in
      "  " ^ str_of_cl f ^ "(" ^ String.concat ", " args ^ ");\n"
  | HLaunch (k, g, b, s, args) ->
      let stream = match s with None -> "0" | Some x -> str_of_cl x in
      "  hipLaunchKernelGGL(" ^ str_of_cl k ^ ", dim3(" ^ render_expr g ^ "), dim3("
      ^ render_expr b ^ "), 0, " ^ stream ^ ", "
      ^ String.concat ", " (List.map render_expr args)
      ^ ");\n"
  | HHostCode (t, _) -> "  " ^ str_of_cl t ^ "\n"

let starts_include = function HHostCode (t, _) -> is_include (str_of_cl t) | _ -> false

let die_usage () =
  prerr_endline "usage: hip_print <in.minihip.json> -o <out.hip>";
  exit 3

let () =
  let input = ref "" and output = ref "" in
  let i = ref 1 in
  while !i < Array.length Sys.argv do
    let a = Sys.argv.(!i) in
    if a = "-o" && !i + 1 < Array.length Sys.argv then (
      output := Sys.argv.(!i + 1);
      i := !i + 2)
    else if a <> "" && a.[0] <> '-' then (
      input := a;
      incr i)
    else (
      prerr_endline ("hip_print: unknown arg: " ^ a);
      exit 3)
  done;
  if !input = "" || !output = "" then die_usage ();
  let doc =
    try Yojson.Basic.from_file !input
    with Sys_error e ->
      prerr_endline ("hip_print: " ^ e);
      exit 3
  in
  let get name =
    match doc with
    | `Assoc fields -> (
        match List.assoc_opt name fields with
        | Some v -> v
        | None ->
            prerr_endline ("hip_print: missing field: " ^ name);
            exit 3)
    | _ ->
        prerr_endline "hip_print: envelope must be an object";
        exit 3
  in
  let schema = match get "schema" with `String s -> s | _ -> "" in
  if schema <> "minihip/v1" then (
    prerr_endline ("hip_print: expected schema minihip/v1, got: " ^ schema);
    exit 3);
  let prog =
    match get "program" with
    | `Null ->
        prerr_endline "hip_print: null program";
        exit 3
    | p -> (
        try program_of_json p
        with Json_error e ->
          prerr_endline ("hip_print: bad program: " ^ e);
          exit 3)
  in
  (match str_of_cl prog.pheader with
  | "hip/hip_runtime.h" -> ()
  | h ->
      prerr_endline ("hip_print: unexpected header: " ^ h);
      exit 3);
  let includes, rest = List.partition starts_include prog.phost in
  let render_inc = function
    | HHostCode (t, _) -> str_of_cl t ^ "\n"
    | _ -> assert false
  in
  emit "#include <hip/hip_runtime.h>\n";
  List.iter (fun n -> emit (render_inc n)) includes;
  emit "\n";
  List.iter (fun k -> emit (render_kernel k ^ "\n")) prog.pkernels;
  emit "int main() {\n";
  List.iter (fun n -> emit (render_host_node n)) rest;
  emit "}\n";
  let oc = open_out !output in
  output_string oc (Buffer.contents buf);
  close_out oc
