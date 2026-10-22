module Ds = Datascript
module Dev = Dev_query
module Wire = Dev.Wire
module Graph = Graph_read

type row = Block of Cache_model.block | Cells of string list
type result = {kind : string; source : string; rows : row list; error : string option}

let field key = function
  | Ds.QueryFormMap fields -> List.assoc_opt (Ds.QueryFormKeyword key) fields
  | _ -> None

let forms = function
  | Some (Ds.QueryFormList xs | Ds.QueryFormVector xs | Ds.QueryFormSet xs) -> xs
  | _ -> []

let rec pulled_value = function
  | Ds.Pulled_scalar value -> value
  | Ds.Pulled_many values -> Ds.Vector (List.map pulled_value values)
  | Ds.Pulled_entity entity -> pulled_entity entity
and pulled_entity entity =
  Ds.Map ((Ds.Keyword "db/id", Ds.Int64 (Int64.of_int entity.Ds.pulled_id)) ::
    List.map (fun (key, value) -> key, pulled_value value) entity.pulled_attrs)

let wire_cell = function
  | Ds.Result_entity eid -> Wire.Tagged ("datascript/Entity", Wire.Int eid)
  | Ds.Result_pull entity -> Dev.Ds_wire.transit_of_value (pulled_entity entity)
  | Ds.Result_value value -> Dev.Ds_wire.transit_of_value value
  | Ds.Result_attr attr -> Wire.Keyword attr
  | Ds.Result_db _ -> Wire.String "<database>"

let cell_eid db = function
  | Wire.Tagged ("datascript/Entity", Wire.Int eid) -> Some eid
  | Wire.Map fields ->
    (match List.assoc_opt (Wire.Keyword "block/uuid") fields with
     | Some (Wire.Uuid uuid) -> Ds.entid db "block/uuid" (Ds.Uuid uuid)
     | _ -> (match List.assoc_opt (Wire.Keyword "db/id") fields with
         | Some (Wire.Int eid) -> Some eid
         | Some (Wire.Int64 eid) -> Some (Int64.to_int eid)
         | _ -> None))
  | _ -> None

let eid_of_result = function
  | Ds.Result_entity eid -> Some eid
  | Ds.Result_pull entity -> Some entity.Ds.pulled_id
  | _ -> None

let hidden db eid =
  Graph.page_is_hidden db eid

let block db eid =
  match Graph.page_block (fun text -> Ok text) db eid with
  | Some value -> Some value
  | None -> Graph.block ~with_breadcrumbs:true (fun text -> Ok text) db eid

let cell_text db cell =
  match cell_eid db cell with
  | Some eid -> Option.value ~default:(string_of_int eid)
      (Graph.string_value (Graph.value db eid "block/title"))
  | None ->
    let value = Dev.Ds_wire.value_of_transit cell in
    match value with Ds.String text -> text | _ -> Dev.Edn_util.pr_str value

let normalize_rows db wire_rows =
  List.map (fun row ->
    let cells = match row with Wire.Array xs | Wire.List xs -> xs | value -> [value] in
    match cells with
    | [cell] ->
      (match Option.bind (cell_eid db cell) (block db) with
       | Some value -> Block value
       | None -> Cells [cell_text db cell])
    | _ -> Cells (List.map (cell_text db) cells)) wire_rows

let filter_rows db owner definition remove_children rows =
  let rows = List.filter (function
    | [cell] -> (match eid_of_result cell with
        | Some eid -> eid <> owner && eid <> definition && not (hidden db eid)
        | None -> true)
    | _ -> true) rows in
  let ids = Hashtbl.create (List.length rows) in
  List.iter (function [cell] -> Option.iter (fun id -> Hashtbl.replace ids id ()) (eid_of_result cell)
    | _ -> ()) rows;
  let nested eid =
    let seen = Hashtbl.create 8 in
    let rec walk eid =
      if Hashtbl.mem seen eid then false
      else begin
        Hashtbl.add seen eid ();
        match Graph.ref_eids db eid "block/parent" with
        | parent :: _ when parent <> eid -> Hashtbl.mem ids parent || walk parent
        | _ -> false
      end
    in walk eid
  in
  List.filter (function
    | [cell] -> (match eid_of_result cell with
        | Some eid -> not remove_children || not (nested eid)
        | None -> true)
    | _ -> true) rows

let source_for db definition =
  Option.value ~default:"" (Graph.string_value (Graph.value db definition "block/title"))

let execute ?current_page db owner definition source =
  let day = Cache_model.journal_day_for_ms (int_of_float (Unix.gettimeofday () *. 1000.)) in
  let opts : Dev.Db_query_dsl.exec_opts = {
    opt_cards = Graph.entity_is_instance_of db owner "logseq.class/Cards";
    opt_block_attrs = Some "[*]";
    opt_current_page_title = current_page;
    opt_today_day = Dev.Time.local_date_of_journal_day (Dev.Time.local_tz ()) day;
  } in
  let advanced = try Some (Ds.Parser.read_edn source) with _ -> None in
  let config = match advanced with Some (Ds.QueryFormMap _ as form) -> Some form | _ -> None in
  let kind = if Option.is_some config then "advanced" else "simple" in
  if String.trim source = "" then {kind; source; rows = []; error = None}
  else
    let query_rows, transform, remove_children = match config with
      | Some config ->
        List.iter (fun name -> match field name config with
          | None | Some (Ds.QueryFormVector _ | Ds.QueryFormList _) -> ()
          | _ -> invalid_arg ("Advanced query :" ^ name ^ " must be a sequence")) ["inputs"; "rules"];
        (match field "remove-block-children?" config with
         | None | Some (Ds.QueryFormBool _) -> ()
         | _ -> invalid_arg "Advanced query :remove-block-children? must be a boolean");
        if Option.is_some (field "view" config) then
          invalid_arg "Custom Hiccup query views are not supported on mobile";
        let query_form = match field "query" config with
          | Some value -> value | None -> invalid_arg "Advanced query requires :query" in
        let rows = match query_form with
          | Ds.QueryFormVector (Ds.QueryFormKeyword "find" :: _ as query) ->
            let ctx = [Wire.Keyword "current-block-uuid", Wire.Uuid (Option.get (Graph.uuid_for_eid db owner));
              Wire.Keyword "today-day", Wire.Int day]
              @ (match current_page with Some title -> [Wire.Keyword "current-page-title", Wire.String title] | None -> []) in
            let inputs = forms (field "inputs" config) |> List.map (fun f ->
              Dev.Ds_wire.transit_of_value (Dev.Edn_util.read_string (Dev.Ds_wire.edn_of_query_form f))) in
            Dev.execute_custom_query_typed db query inputs (forms (field "rules" config)) ctx
          | _ -> (match Dev.Db_query_dsl.execute_query db (Dev.Ds_wire.edn_of_query_form query_form) opts with
              | Some rows -> rows | None -> invalid_arg "Invalid query DSL") in
        rows, field "result-transform" config, field "remove-block-children?" config <> Some (Ds.QueryFormBool false)
      | None ->
        (match Dev.Db_query_dsl.execute_query db source opts with
         | Some rows -> rows, None, true
         | None -> invalid_arg "Invalid query DSL") in
    let rows = filter_rows db owner definition remove_children query_rows in
    let block_results = List.for_all (function [cell] -> Option.is_some (eid_of_result cell) | _ -> false) rows in
    let wire_rows = match transform with
      | Some form ->
        let encoded = List.map (fun row -> if block_results then wire_cell (List.hd row)
          else Wire.Array (List.map wire_cell row)) rows in
        let entity_attr eid attr = Option.value ~default:Ds.Nil (Graph.value db eid attr) in
        (match Dev.Edn_eval.apply_edn ~entity_attr (Dev.Ds_wire.edn_of_query_form form) encoded with
         | Wire.Array xs | Wire.List xs | Wire.Set xs -> xs
         | _ -> invalid_arg "Query result transform must return a collection")
      | None -> List.map (fun row -> Wire.Array (List.map wire_cell row)) rows in
    {kind; source; rows = normalize_rows db wire_rows; error = None}

let is_query db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | None -> false
  | Some eid -> Graph.ref_eids db eid "logseq.property/query" <> []
      || Graph.entity_is_instance_of db eid "logseq.class/Query"

let render ?current_page db uuid =
  match Ds.entid db "block/uuid" (Ds.Uuid uuid) with
  | None -> None
  | Some eid ->
    let definitions = Graph.ref_eids db eid "logseq.property/query" in
    if definitions = [] && not (Graph.entity_is_instance_of db eid "logseq.class/Query") then None
    else
      let source = ref "" in
      try
        let definition = match definitions with
          | id :: _ -> id | [] -> invalid_arg "Query definition is missing" in
        source := source_for db definition;
        let current_page = match current_page with Some _ -> current_page | None ->
          Option.bind (List.nth_opt (Graph.ref_eids db eid "block/page") 0)
            (fun page -> Graph.string_value (Graph.value db page "block/title")) in
        Some (execute ?current_page db eid definition !source)
      with error ->
        let message = match error with Invalid_argument message | Failure message -> message
          | _ -> Printexc.to_string error in
        Some {kind = "error"; source = !source; rows = []; error = Some message}

let owner_uuids db =
  let ids = Hashtbl.create 8 in
  let add (datom : Ds.datom) = Hashtbl.replace ids datom.e () in
  Seq.iter add (Ds.Db.datoms db Ds.Aevt ~a:"logseq.property/query" ());
  Option.iter (fun query_class ->
    List.iter (fun id -> Seq.iter add (Datascript_value.datoms_by_ref db Ds.Aevt "block/tags" id))
      (Graph.class_descendants db query_class))
    (Ds.entid db "db/ident" (Ds.Keyword "logseq.class/Query"));
  Hashtbl.fold (fun eid () values -> match Graph.uuid_for_eid db eid with
    | Some uuid -> uuid :: values | None -> values) ids []

let to_yojson encode result =
  `Assoc ["kind", `String result.kind; "source", `String result.source;
    "error", (match result.error with Some message -> `String message | None -> `Null);
    "rows", `List (List.map (function
      | Block block -> `Assoc ["block", encode block]
      | Cells cells -> `Assoc ["cells", `List (List.map (fun s -> `String s) cells)]) result.rows)]
