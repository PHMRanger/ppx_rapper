open Core
open Ppxlib
module Buildef = Ast_builder.Default

let up_to_last xs = List.take xs (List.length xs - 1)

let caqti_type_of_param ~loc Query.{ typ = _, base_type; opt; _ } =
  let base_expr =
    match base_type with
    | "string" -> [%expr string]
    | "int" -> [%expr int]
    | "bool" -> [%expr bool]
    | _ -> failwith (Printf.sprintf "Unsupported base type %s" base_type)
  in
  match opt with
  | true -> Buildef.(pexp_apply ~loc [%expr option] [ (Nolabel, base_expr) ])
  | false -> base_expr

let make_caqti_type_tup ~loc in_params =
  let type_exprs = List.map ~f:(caqti_type_of_param ~loc) in_params in
  let f elem_type_expr apply_expr =
    [%expr tup2 [%e elem_type_expr] [%e apply_expr]]
  in
  List.fold_right ~f ~init:(List.last_exn type_exprs) (up_to_last type_exprs)

let pexp_idents_of_params ~loc params =
  List.map
    ~f:(fun param ->
      Buildef.pexp_ident ~loc (Loc.make ~loc (Lident param.Query.name)))
    params

let ppat_var_of_params ~loc params =
  List.map
    ~f:(fun param -> Buildef.ppat_var ~loc (Loc.make ~loc param.Query.name))
    params

let make_nested_tuple_expression ~loc params =
  match List.length params with
  (* With current design, 0-tuple case should not occur. *)
  | 0 -> [%expr ()]
  | _ ->
      let idents = pexp_idents_of_params ~loc params in
      let f ident accum = Buildef.pexp_tuple ~loc [ ident; accum ] in
      List.fold_right ~f ~init:(List.last_exn idents) (up_to_last idents)

let make_nested_tuple_pattern ~loc params =
  match List.length params with
  (* With current design, 0-tuple case should not occur. *)
  | 0 -> failwith "0-tuple pattern not implemented"
  | _ ->
      let idents = ppat_var_of_params ~loc params in
      let f ident accum = Buildef.ppat_tuple ~loc [ ident; accum ] in
      List.fold_right ~f ~init:(List.last_exn idents) (up_to_last idents)

let make_flat_tuple ~loc params =
  Buildef.pexp_tuple ~loc (pexp_idents_of_params ~loc params)

let make_function_body_find ~loc connection_function_expr in_params out_params =
  let input_nested_tuples = make_nested_tuple_expression ~loc in_params in
  match List.length out_params with
  | 0 | 1 ->
      [%expr [%e connection_function_expr] query [%e input_nested_tuples]]
  | _ ->
      let x = make_nested_tuple_pattern ~loc out_params in
      let output_flat_tuple = make_flat_tuple ~loc out_params in
      [%expr
        let f result =
          Result.map ~f:(fun [%p x] -> [%e output_flat_tuple]) result
        in
        Lwt.map f ([%e connection_function_expr] query [%e input_nested_tuples])]

let make_function_body_map map_expr ~loc connection_function_expr in_params
    out_params =
  let input_nested_tuples = make_nested_tuple_expression ~loc in_params in
  match List.length out_params with
  | 0 | 1 ->
      [%expr [%e connection_function_expr] query [%e input_nested_tuples]]
  | _ ->
      let x = make_nested_tuple_pattern ~loc out_params in
      let output_flat_tuple = make_flat_tuple ~loc out_params in
      [%expr
        let f result =
          let g [%p x] = [%e output_flat_tuple] in
          Result.map ~f:([%e map_expr] ~f:g) result
        in
        Lwt.map f ([%e connection_function_expr] query [%e input_nested_tuples])]

let make_function_body_collect ~loc =
  make_function_body_map [%expr List.map] ~loc

let make_function_body_find_opt ~loc =
  make_function_body_map [%expr Option.map] ~loc

(** Generates code like [fun ~x ~y ~z -> Db.some_function query (x, (y, z))]. *)
let make_query_function ~loc function_body_factory connection_function_expr
    in_params out_params =
  if List.is_empty in_params then
    [%expr fun () -> [%e connection_function_expr] query ()]
  else
    let deduped_in_params =
      match Query.remove_duplicates in_params with
      | Ok deduplicated -> deduplicated
      | Error _ -> failwith "Duplicated input parameters with conflicting specs"
    in
    (* Tuples should have duplicates if they exist. *)
    let body =
      function_body_factory ~loc connection_function_expr in_params out_params
    in
    let f in_param body_so_far =
      let name = in_param.Query.name in
      let pattern = Buildef.ppat_var ~loc (Loc.make ~loc name) in
      Buildef.pexp_fun ~loc (Labelled name) None pattern body_so_far
    in
    List.fold_right ~f ~init:body deduped_in_params

(* TODO - sort this out *)
let make_exec_function ~loc =
  make_query_function ~loc make_function_body_find [%expr Db.exec]

let make_find_function ~loc =
  make_query_function ~loc make_function_body_find [%expr Db.find]

let make_find_opt_function ~loc =
  make_query_function ~loc make_function_body_find_opt [%expr Db.find_opt]

let make_collect_list_function ~loc =
  make_query_function ~loc make_function_body_collect [%expr Db.collect_list]

let expand ~loc ~path:_ action query =
  let parsed_query =
    match Query.parse query with
    | Ok parsed_query -> parsed_query
    | Error _ -> failwith "Couldn't parse query"
  in
  let inputs_caqti_type =
    match List.length parsed_query.in_params with
    | 0 -> [%expr unit]
    | _ -> make_caqti_type_tup ~loc parsed_query.in_params
  in
  let outputs_caqti_type =
    match List.length parsed_query.out_params with
    | 0 -> [%expr unit]
    | _ -> make_caqti_type_tup ~loc parsed_query.out_params
  in
  let parsed_sql = Buildef.estring ~loc parsed_query.sql in
  let expand_get caqti_request_function_expr make_function =
    [%expr
      let query =
        Caqti_request.([%e caqti_request_function_expr])
          Caqti_type.([%e inputs_caqti_type])
          Caqti_type.([%e outputs_caqti_type])
          [%e parsed_sql]
      in
      let wrapped (module Db : Caqti_lwt.CONNECTION) =
        [%e make_function ~loc parsed_query.in_params parsed_query.out_params]
      in
      wrapped]
  in
  match action with
  | "execute" ->
      [%expr
        let query =
          Caqti_request.exec Caqti_type.([%e inputs_caqti_type]) [%e parsed_sql]
        in
        let wrapped (module Db : Caqti_lwt.CONNECTION) =
          [%e
            make_exec_function ~loc parsed_query.in_params
              parsed_query.out_params]
        in
        wrapped]
  | "get_one" -> expand_get [%expr find] make_find_function
  | "get_opt" -> expand_get [%expr find_opt] make_find_opt_function
  | "get_many" -> expand_get [%expr collect] make_collect_list_function
  | _ -> failwith "Supported actions are execute, get_one, get_opt and get_many"

(** Captures [[%rapper get_one "SELECT id FROM things WHERE condition"]] *)
let pattern =
  let open Ast_pattern in
  let query_action = pexp_ident (lident __) in
  let query = pair nolabel (estring __) in
  Ast_pattern.(pexp_apply query_action (query ^:: nil))

let name = "rapper"

let ext =
  Extension.declare name Extension.Context.expression
    Ast_pattern.(single_expr_payload pattern)
    expand

let () = Driver.register_transformation name ~extensions:[ ext ]
