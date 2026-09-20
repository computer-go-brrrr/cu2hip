(* minimap — OCaml driver (G4): MiniCUDA.json -> MiniHIP.json.
   Runs the EXTRACTED verified core (Map.map_program) on parsed AST.
   Unverified shell around a verified function; equivalence with
   tests/fixtures/*.minihip.json is the regression gate.

   Usage: minimap <in.minicuda.json> -o <out.minihip.json>
   Exit: 0 ok | 2 unmapped API (fail closed) | 3 contract/IO error. *)

open Cu2hip_core.Mini_json

let die_usage () =
  prerr_endline "usage: minimap <in.minicuda.json> -o <out.minihip.json>";
  exit 3

let json_of_diagnostic (code, feature, loc, hint) =
  `Assoc
    [
      ("code", `String code);
      ("feature", `String feature);
      ("loc", `String loc);
      ("hint", `String hint);
    ]

let () =
  let input = ref "" and output = ref "" in
  let i = ref 1 in
  while !i < Array.length Sys.argv do
    let a = Sys.argv.(!i) in
    if a = "--version" || a = "-V" then (
      print_endline "minimap 0.1.0";
      exit 0)
    else if a = "-o" && !i + 1 < Array.length Sys.argv then (
      output := Sys.argv.(!i + 1);
      i := !i + 2)
    else if a <> "" && a.[0] <> '-' then (
      input := a;
      incr i)
    else (
      prerr_endline ("minimap: unknown arg: " ^ a);
      exit 3)
  done;
  if !input = "" || !output = "" then die_usage ();
  let doc =
    try Yojson.Basic.from_file !input
    with Sys_error e ->
      prerr_endline ("minimap: " ^ e);
      exit 3
  in
  let get name =
    try
      match doc with
      | `Assoc fields -> (
          match List.assoc_opt name fields with
          | Some v -> v
          | None -> raise (Json_error ("missing field: " ^ name)))
      | _ -> raise (Json_error "envelope must be an object")
    with Json_error e ->
      prerr_endline ("minimap: bad envelope: " ^ e);
      exit 3
  in
  let schema =
    (match get "schema" with `String s -> s | _ -> "")
  in
  if schema <> "minicuda/v1" then (
    prerr_endline ("minimap: expected schema minicuda/v1, got: " ^ schema);
    exit 3);
  let source =
    match get "source" with `String s -> s | _ -> ""
  in
  let program_json = get "program" in
  (match program_json with
  | `Null ->
      prerr_endline "minimap: contract violation: null program (frontend must exit 2 itself)";
      exit 3
  | _ -> ());
  let prog =
    try program_of_json program_json
    with Json_error e ->
      prerr_endline ("minimap: bad program: " ^ e);
      exit 3
  in
  (match Extracted.Map.map_program prog with
  | None ->
      let oc = open_out !output in
      Yojson.Basic.to_channel oc
        (`Assoc
          [
            ("schema", `String "minihip/v1");
            ("source", `String source);
            ("program", `Null);
            ( "diagnostics",
              `List
                [
                  json_of_diagnostic
                    ( "Unsupported",
                      "unmapped-api",
                      source,
                      "an API name has no HIP counterpart (see SUPPORTED.md)" );
                ] );
          ]);
      output_char oc '\n';
      close_out oc;
      prerr_endline "minimap: unmapped API (see output diagnostics)";
      exit 2
  | Some hip ->
      let oc = open_out !output in
      Yojson.Basic.to_channel oc
        (`Assoc
          [
            ("schema", `String "minihip/v1");
            ("source", `String source);
            ("program", json_of_program hip);
            ("diagnostics", `List []);
          ]);
      output_char oc '\n';
      close_out oc)
