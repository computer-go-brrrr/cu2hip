(* mini_json.ml — Yojson <-> extracted MiniCUDA/MiniHIP AST (G4).
   Unverified shell: every function here is Tests-covered, never proved.
   The AST shapes are enforced by equivalence with tests/fixtures/*.json
   (driver output must equal vectorAdd.minihip.json exactly). *)

open Extracted.MiniCuda

exception Json_error of string

let str_of_cl l = String.of_seq (List.to_seq l)
let cl_of_str s = List.of_seq (String.to_seq s)

(* ---------- generic accessors ---------- *)

let field (obj : Yojson.Basic.t) name =
  match obj with
  | `Assoc fields -> (
      match List.assoc_opt name fields with
      | Some v -> v
      | None -> raise (Json_error ("missing field: " ^ name)))
  | _ -> raise (Json_error ("expected object for field: " ^ name))

let as_string : Yojson.Basic.t -> string = function
  | `String s -> s
  | _ -> raise (Json_error "expected string")

let as_int : Yojson.Basic.t -> int = function
  | `Int i -> i
  | _ -> raise (Json_error "expected int")

let as_float : Yojson.Basic.t -> float = function
  | `Float f -> f
  | `Int i -> float_of_int i
  | _ -> raise (Json_error "expected float")

let as_list : Yojson.Basic.t -> Yojson.Basic.t list = function
  | `List l -> l
  | _ -> raise (Json_error "expected list")

(* ---------- enums ---------- *)

let scalarTy_of_string = function
  | "int" -> TyInt
  | "float" -> TyFloat
  | "double" -> TyDouble
  | s -> raise (Json_error ("scalarTy: " ^ s))

let string_of_scalarTy = function
  | TyInt -> "int"
  | TyFloat -> "float"
  | TyDouble -> "double"

let binop_of_string = function
  | "+" -> BAdd | "-" -> BSub | "*" -> BMul | "/" -> BDiv | "%" -> BMod
  | "<" -> BLt | "<=" -> BLe | ">" -> BGt | ">=" -> BGe
  | "==" -> BEq | "!=" -> BNe | "&&" -> BAnd | "||" -> BOr
  | s -> raise (Json_error ("binop: " ^ s))

let string_of_binop = function
  | BAdd -> "+" | BSub -> "-" | BMul -> "*" | BDiv -> "/" | BMod -> "%"
  | BLt -> "<" | BLe -> "<=" | BGt -> ">" | BGe -> ">="
  | BEq -> "==" | BNe -> "!=" | BAnd -> "&&" | BOr -> "||"

let unop_of_string = function
  | "-" -> UNeg
  | "!" -> UNot
  | s -> raise (Json_error ("unop: " ^ s))

let string_of_unop = function UNeg -> "-" | UNot -> "!"

let builtin_of_string = function
  | "threadIdx.x" -> B_tidx | "threadIdx.y" -> B_tidy | "threadIdx.z" -> B_tidz
  | "blockIdx.x" -> B_bidx | "blockIdx.y" -> B_bidy | "blockIdx.z" -> B_bidz
  | "blockDim.x" -> B_bdimx | "blockDim.y" -> B_bdimy | "blockDim.z" -> B_bdimz
  | "gridDim.x" -> B_gdimx | "gridDim.y" -> B_gdimy | "gridDim.z" -> B_gdimz
  | s -> raise (Json_error ("builtin: " ^ s))

let string_of_builtin = function
  | B_tidx -> "threadIdx.x" | B_tidy -> "threadIdx.y" | B_tidz -> "threadIdx.z"
  | B_bidx -> "blockIdx.x" | B_bidy -> "blockIdx.y" | B_bidz -> "blockIdx.z"
  | B_bdimx -> "blockDim.x" | B_bdimy -> "blockDim.y" | B_bdimz -> "blockDim.z"
  | B_gdimx -> "gridDim.x" | B_gdimy -> "gridDim.y" | B_gdimz -> "gridDim.z"

let copyKind_of_string = function
  | "HostToDevice" -> CK_H2D
  | "DeviceToHost" -> CK_D2H
  | "DeviceToDevice" -> CK_D2D
  | "HostToHost" -> CK_H2H
  | s -> raise (Json_error ("copyKind: " ^ s))

let string_of_copyKind = function
  | CK_H2D -> "HostToDevice"
  | CK_D2H -> "DeviceToHost"
  | CK_D2D -> "DeviceToDevice"
  | CK_H2H -> "HostToHost"

(* ---------- expressions / statements ---------- *)

let rec expr_of_json (j : Yojson.Basic.t) =
  match as_string (field j "kind") with
  | "var" -> EVar (cl_of_str (as_string (field j "name")))
  | "int" -> EInt (as_int (field j "value"))
  | "float" -> EFloat (Float64.of_float (as_float (field j "value")))
  | "binop" ->
      EBinop
        ( binop_of_string (as_string (field j "op")),
          expr_of_json (field j "left"),
          expr_of_json (field j "right") )
  | "unop" ->
      EUnop (unop_of_string (as_string (field j "op")), expr_of_json (field j "expr"))
  | "subscript" ->
      ESubscript (expr_of_json (field j "base"), expr_of_json (field j "index"))
  | "builtin" -> EBuiltin (builtin_of_string (as_string (field j "name")))
  | "addrof" -> EAddrof (cl_of_str (as_string (field j "name")))
  | "call" ->
      ECall
        ( cl_of_str (as_string (field j "name")),
          List.map expr_of_json (as_list (field j "args")) )
  | k -> raise (Json_error ("expr kind: " ^ k))

let rec json_of_expr : Extracted.MiniCuda.expr -> Yojson.Basic.t = function
  | EVar x -> `Assoc [ ("kind", `String "var"); ("name", `String (str_of_cl x)) ]
  | EInt z -> `Assoc [ ("kind", `String "int"); ("value", `Int z) ]
  | EFloat f ->
      `Assoc [ ("kind", `String "float"); ("value", `Float (Float64.to_float f)) ]
  | EBinop (op, l, r) ->
      `Assoc
        [
          ("kind", `String "binop");
          ("op", `String (string_of_binop op));
          ("left", json_of_expr l);
          ("right", json_of_expr r);
        ]
  | EUnop (op, e) ->
      `Assoc
        [
          ("kind", `String "unop");
          ("op", `String (string_of_unop op));
          ("expr", json_of_expr e);
        ]
  | ESubscript (b, i) ->
      `Assoc
        [
          ("kind", `String "subscript");
          ("base", json_of_expr b);
          ("index", json_of_expr i);
        ]
  | EBuiltin b ->
      `Assoc [ ("kind", `String "builtin"); ("name", `String (string_of_builtin b)) ]
  | EAddrof x -> `Assoc [ ("kind", `String "addrof"); ("name", `String (str_of_cl x)) ]
  | ECall (f, args) ->
      `Assoc
        [
          ("kind", `String "call");
          ("name", `String (str_of_cl f));
          ("args", `List (List.map json_of_expr args));
        ]

let rec stmt_of_json (j : Yojson.Basic.t) =
  match as_string (field j "kind") with
  | "let" ->
      SLet
        ( cl_of_str (as_string (field j "name")),
          scalarTy_of_string (as_string (field j "type")),
          expr_of_json (field j "value") )
  | "store" -> SStore (expr_of_json (field j "target"), expr_of_json (field j "value"))
  | "if" ->
      SIf
        ( expr_of_json (field j "cond"),
          List.map stmt_of_json (as_list (field j "then")),
          (match j with
          | `Assoc fields -> (
              match List.assoc_opt "else" fields with
              | None -> []
              | Some e -> List.map stmt_of_json (as_list e))
          | _ -> []) )
  | "syncthreads" -> SSync
  | "expr_stmt" -> SExpr (expr_of_json (field j "expr"))
  | k -> raise (Json_error ("stmt kind: " ^ k))

let rec json_of_stmt : Extracted.MiniCuda.stmt -> Yojson.Basic.t = function
  | SLet (x, t, e) ->
      `Assoc
        [
          ("kind", `String "let");
          ("name", `String (str_of_cl x));
          ("type", `String (string_of_scalarTy t));
          ("value", json_of_expr e);
        ]
  | SStore (t, v) ->
      `Assoc
        [
          ("kind", `String "store");
          ("target", json_of_expr t);
          ("value", json_of_expr v);
        ]
  | SIf (c, th, el) ->
      `Assoc
        [
          ("kind", `String "if");
          ("cond", json_of_expr c);
          ("then", `List (List.map json_of_stmt th));
          ("else", `List (List.map json_of_stmt el));
        ]
  | SSync -> `Assoc [ ("kind", `String "syncthreads") ]
  | SExpr e -> `Assoc [ ("kind", `String "expr_stmt"); ("expr", json_of_expr e) ]

(* ---------- kernels / host / program ---------- *)

let param_of_json (j : Yojson.Basic.t) =
  {
    pname = cl_of_str (as_string (field j "name"));
    pty = scalarTy_of_string (as_string (field j "type"));
    pptr = (match field j "pointer" with `Bool b -> b | _ -> raise (Json_error "pointer"));
  }

let json_of_param p =
  `Assoc
    [
      ("name", `String (str_of_cl p.pname));
      ("type", `String (string_of_scalarTy p.pty));
      ("pointer", `Bool p.pptr);
    ]

let shared_of_json (j : Yojson.Basic.t) =
  {
    sname = cl_of_str (as_string (field j "name"));
    sty = scalarTy_of_string (as_string (field j "type"));
    ssize = as_int (field j "size");
  }

let json_of_shared s =
  `Assoc
    [
      ("name", `String (str_of_cl s.sname));
      ("type", `String (string_of_scalarTy s.sty));
      ("size", `Int s.ssize);
    ]

let kernel_of_json (j : Yojson.Basic.t) =
  if as_string (field j "kind") <> "kernel" then raise (Json_error "kernel kind");
  {
    kname = cl_of_str (as_string (field j "name"));
    kparams = List.map param_of_json (as_list (field j "params"));
    kshared = List.map shared_of_json (as_list (field j "shared"));
    kbody = List.map stmt_of_json (as_list (field j "body"));
  }

let json_of_kernel k =
  `Assoc
    [
      ("kind", `String "kernel");
      ("name", `String (str_of_cl k.kname));
      ("qualifier", `String "__global__");
      ("params", `List (List.map json_of_param k.kparams));
      ("shared", `List (List.map json_of_shared k.kshared));
      ("body", `List (List.map json_of_stmt k.kbody));
    ]

let hostNode_of_json (j : Yojson.Basic.t) =
  match as_string (field j "kind") with
  | "api" ->
      HApi
        ( cl_of_str (as_string (field j "name")),
          List.map expr_of_json (as_list (field j "args")),
          (match j with
          | `Assoc fields -> (
              match List.assoc_opt "copyKind" fields with
              | None -> None
              | Some c -> Some (copyKind_of_string (as_string c)))
          | _ -> None) )
  | "launch" ->
      HLaunch
        ( cl_of_str (as_string (field j "kernel")),
          expr_of_json (field j "grid"),
          expr_of_json (field j "block"),
          (match field j "stream" with
          | `Null -> None
          | `String s -> Some (cl_of_str s)
          | _ -> raise (Json_error "stream")),
          List.map expr_of_json (as_list (field j "args")) )
  | "host_code" ->
      HHostCode
        (cl_of_str (as_string (field j "text")), cl_of_str (as_string (field j "loc")))
  | k -> raise (Json_error ("hostNode kind: " ^ k))

let json_of_hostNode = function
  | HApi (f, args, ck) ->
      `Assoc
        ([
           ("kind", `String "api");
           ("name", `String (str_of_cl f));
           ("args", `List (List.map json_of_expr args));
         ]
        @ (match ck with
           | None -> []
           | Some c -> [ ("copyKind", `String (string_of_copyKind c)) ]))
  | HLaunch (k, g, b, s, args) ->
      `Assoc
        [
          ("kind", `String "launch");
          ("kernel", `String (str_of_cl k));
          ("grid", json_of_expr g);
          ("block", json_of_expr b);
          ("stream", (match s with None -> `Null | Some x -> `String (str_of_cl x)));
          ("args", `List (List.map json_of_expr args));
        ]
  | HHostCode (t, l) ->
      `Assoc
        [
          ("kind", `String "host_code");
          ("text", `String (str_of_cl t));
          ("loc", `String (str_of_cl l));
        ]

let program_of_json (j : Yojson.Basic.t) =
  {
    pheader = cl_of_str (as_string (field j "header"));
    pkernels = List.map kernel_of_json (as_list (field j "kernels"));
    phost = List.map hostNode_of_json (as_list (field j "host"));
  }

let json_of_program p =
  `Assoc
    [
      ("header", `String (str_of_cl p.pheader));
      ("kernels", `List (List.map json_of_kernel p.pkernels));
      ("host", `List (List.map json_of_hostNode p.phost));
    ]
