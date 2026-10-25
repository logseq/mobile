module Ds = Datascript
module G = Graph_read
module Ops = Pending_ops
module J = Yojson.Basic

let member key = function `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields) | _ -> `Null
let text = function `String value -> value | _ -> ""
let required key json = match member key json with `String value when value <> "" -> value
  | _ -> invalid_arg ("Missing " ^ key)
let key name = Ds.Keyword name
let ds_field name = function Ds.Map fields -> Option.value ~default:Ds.Nil (List.assoc_opt (key name) fields) | _ -> Ds.Nil
let values = function Ds.Vector xs | Ds.List xs | Ds.Set xs -> xs | Ds.Nil -> [] | value -> [value]
let get db eid attr = Option.value ~default:Ds.Nil (G.value db eid attr)
let eid db uuid = match Ds.entid db "block/uuid" (Ds.Uuid uuid) with Some eid -> eid | None -> invalid_arg "Object no longer exists"
let attr_eid db attr = Ds.entid db "db/ident" (key attr)
let uuid db id = Option.value ~default:"" (G.uuid_for_eid db id)
let ident db id = match get db id "db/ident" with Ds.Keyword name -> name | _ -> ""
let attr_values db id attr = Ds.Db.datoms db Ds.Eavt ~e:id ~a:attr () |> Seq.map (fun (d : Ds.datom) -> d.v) |> List.of_seq
let raw db id attr = match attr_values db id attr with
  | [] -> None | [v] when not (List.exists (fun (name, spec) -> name = attr && spec.Ds.cardinality = Ds.Many) db.Ds.schema) -> Some v
  | values -> Some (Ds.Set values)
let ref_id db = function Ds.Ref id -> Some id | Ds.Ref_to reference -> Option.map (fun e -> e.Ds.id) (Ds.entity db reference) | _ -> None
let content db value = match ref_id db value with
  | Some id when ident db id = "logseq.property/empty-placeholder" -> Ds.Nil
  | Some id -> (match get db id "block/title" with Ds.Nil -> get db id "logseq.property/value" | value -> value)
  | None -> value
let number = function Ds.Int64 n | Ds.Instant n -> Some (Int64.to_float n) | Ds.Float f when Float.is_finite f -> Some f | _ -> None
let rec display = function
  | Ds.Nil -> "" | Ds.String s | Ds.Keyword s | Ds.Uuid s -> s
  | Ds.Int64 n | Ds.Instant n -> Int64.to_string n
  | Ds.Float f -> if Float.is_integer f then Printf.sprintf "%.0f" f else string_of_float f
  | Ds.Bool b -> string_of_bool b
  | Ds.Set xs | Ds.Vector xs | Ds.List xs -> String.concat ", " (List.map display xs)
  | value -> Dev_query.Edn_util.pr_str value
let rec empty db value = match content db value with
  | Ds.Nil | Ds.Keyword "logseq.property/empty-placeholder" -> true
  | Ds.String value -> String.trim value = ""
  | Ds.Set values | Ds.Vector values | Ds.List values -> List.for_all (empty db) values
  | _ -> false
let contains value input = Outliner_state.includes_case_insensitive value input

type property = {attr : string; title : string; typ : string; many : bool; ref_ : bool; closed : bool; choices : int list; classes : int list}
let property ?owner db attr =
  let id = attr_eid db attr in
  let typ = if attr = "block/tags" then "class" else
    match Option.map (fun id -> get db id "logseq.property/type") id with Some (Ds.Keyword typ) -> typ | _ -> "default" in
  let schema = List.assoc_opt attr db.Ds.schema in
  let all_choices = Option.fold ~none:[] ~some:(G.closed_value_eids db) id in
  let choices = match owner with
    | Some owner -> G.scope_closed_value_eids db ~owner all_choices
    | None -> all_choices in
  {attr; typ; choices; closed = all_choices <> [];
   classes = Option.fold ~none:[] ~some:(fun id -> G.ref_eids db id "logseq.property/classes") id;
   title = (if attr = "block/title" then "Name" else if attr = "block/created-at" then "Created" else
     match Option.map (fun id -> display (get db id "block/title")) id with Some title when title <> "" -> title | _ -> attr);
   many = Option.fold ~none:false ~some:(fun schema -> schema.Ds.cardinality = Ds.Many) schema;
   ref_ = Option.fold ~none:false ~some:(fun schema -> schema.Ds.value_type = Some Ds.RefType) schema}
let node_target_id db p value =
  Option.map (fun id ->
    if p.typ <> "node" || ref_id db (get db id "logseq.property/created-from-property") <> attr_eid db p.attr then id else
    match get db id "block/title" with
    | Ds.String uuid when Ref_text.is_uuid uuid -> Option.value ~default:id (Ds.entid db "block/uuid" (Ds.Uuid uuid))
    | _ -> id) (ref_id db value)

let temporal_value db p value =
  if empty db value then "" else
  if p.typ = "date" then
    (match Option.map (fun id -> get db id "block/journal-day") (ref_id db value) with
     | Some (Ds.Int64 day) -> let day = Int64.to_int day in
       Printf.sprintf "%04d-%02d-%02d" (day / 10000) (day / 100 mod 100) (day mod 100)
     | _ -> "")
  else if p.typ = "datetime" then
    Option.fold ~none:"" ~some:(Printf.sprintf "%.0f") (number (content db value))
  else ""

let property_display db p value =
  if p.typ = "node" && node_target_id db p value <> ref_id db value then
    Option.fold ~none:"" ~some:(fun id -> G.display_title (fun value -> Ok value) db (display (get db id "block/title")))
      (node_target_id db p value)
  else if p.typ = "date" then
    (match Option.bind (ref_id db value) (fun id -> G.int_value (G.value db id "block/journal-day")) with
     | Some day when Journal.valid_day day -> Journal.title db day
     | _ -> "")
  else if p.typ = "datetime" || List.mem p.attr ["block/created-at"; "block/updated-at"] then
    match number (content db value) with
    | Some millis when abs_float millis <= 8640000000000000. ->
      let t = Unix.localtime (millis /. 1000.) in
      Printf.sprintf "%04d-%02d-%02d %02d:%02d" (t.Unix.tm_year + 1900) (t.tm_mon + 1) t.tm_mday t.tm_hour t.tm_min
    | _ -> ""
  else if p.attr = "block/title" then G.display_title (fun text -> Ok text) db (display (content db value))
  else display (content db value)

let public_attr attr = attr = "block/title" || String.starts_with ~prefix:"user.property/" attr
  || List.mem attr ["logseq.property/status"; "logseq.property/priority"; "block/tags"; "block/created-at"; "block/updated-at"]

let rec semantic db value = match ref_id db value with
  | Some id -> let uuid = uuid db id in if uuid <> "" then Ops.Ref_uuid uuid else Ops.Ref_ident (ident db id)
  | None -> (match value with
      | Ds.Set xs -> Ops.Set_value (List.map (semantic db) xs)
      | Ds.Vector xs -> Ops.Vector_value (List.map (semantic db) xs)
      | _ -> match Ops.semantic_value_from_datascript value with Ok value -> value | Error message -> invalid_arg message)
let semantic_json db value = Option.fold ~none:`Null ~some:(fun value -> Ops.semantic_value_json (semantic db value)) value
let rec plain = function
  | Ds.Nil -> `Null | Ds.String s | Ds.Keyword s | Ds.Uuid s -> `String s
  | Ds.Int64 n | Ds.Instant n -> `Int (Int64.to_int n) | Ds.Float f -> `Float f | Ds.Bool b -> `Bool b
  | Ds.Set xs | Ds.Vector xs | Ds.List xs -> `List (List.map plain xs)
  | Ds.Map fields -> `Assoc (List.filter_map (function Ds.Keyword name, value -> Some (name, plain value) | _ -> None) fields)
  | _ -> `Null

let apply_view db feature sorting filters input rows =
  (match filters with
   | Ds.Nil | Ds.Keyword "logseq.property/empty-placeholder" -> ()
   | Ds.Map fields ->
     (match List.assoc_opt (Ds.Keyword "filters") fields with
      | None | Some (Ds.Vector _) | Some (Ds.List _) | Some (Ds.Set _) -> ()
      | _ -> invalid_arg "Invalid filters")
   | _ -> invalid_arg "Invalid filters");
  (match sorting with
   | Ds.Nil | Ds.Keyword "logseq.property/empty-placeholder" -> ()
   | Ds.Vector keys -> List.iter (function
       | Ds.Map _ as key -> (match ds_field "id" key, ds_field "asc?" key with
           | Ds.Keyword _, Ds.Bool _ -> () | _ -> invalid_arg "Invalid sorting")
       | _ -> invalid_arg "Invalid sorting") keys
   | _ -> invalid_arg "Invalid sorting");
  let sorting = Dev_view.sorting_of_value sorting in
  let filters = Dev_view.parse_filters filters in
  let by_id = Hashtbl.create (List.length rows) in
  let entities = List.filter_map (function
    | Query_block.Cells _ -> None
    | Query_block.Block block as row ->
      let id = eid db block.uuid in
      Hashtbl.replace by_id id row;
      Ds.entity db (Ds.Entity_id id)) rows in
  let ids = if feature = "class-objects" then
      List.map (fun (entity : Ds.entity) -> entity.id) entities
      |> fun ids -> Dev_view.filter_eids db ids filters input
      |> fun ids -> Dev_view.sort_eids_by_sorting db ids sorting
    else
      let predicate = Option.value ~default:(fun entity -> Dev_view.row_matched db entity filters input)
          (Dev_view.build_fast_filter_pred db filters input) in
      List.filter predicate entities |> Dev_view.sort_entities db sorting
      |> List.map (fun (entity : Ds.entity) -> entity.id) in
  let blocks = List.filter_map (Hashtbl.find_opt by_id) ids in
  let cells = List.filter (function Query_block.Cells cells ->
      contains (String.concat " " cells) input | _ -> false) rows in
  blocks @ cells

let saved_views db owner feature =
  Datascript_value.datoms_by_ref db Ds.Aevt "logseq.property/view-for" (eid db owner)
  |> Seq.map (fun (d : Ds.datom) -> d.e)
  |> Seq.filter (fun id -> get db id "logseq.property.view/feature-type" = key feature)
  |> List.of_seq |> List.sort (fun a b -> compare (display (get db a "block/order"), a) (display (get db b "block/order"), b))
let columns db view rows =
  let scalar_columns = List.fold_left (fun count -> function Query_block.Cells cells -> max count (List.length cells) | _ -> count) 0 rows in
  if scalar_columns > 0 && List.for_all (function Query_block.Cells _ -> true | _ -> false) rows then
    List.init scalar_columns (fun index -> {attr = "query.result/" ^ string_of_int index;
      title = (if scalar_columns = 1 then "Value" else "Column " ^ string_of_int (index + 1));
      typ = "string"; many = false; ref_ = false; closed = false; choices = []; classes = []})
  else
  let ordered = match view with None -> [] | Some id -> get db id "logseq.property.table/ordered-columns" |> values
    |> List.filter_map (function Ds.Keyword attr -> Some attr | _ -> None) in
  let attrs = Hashtbl.create 16 in
  Hashtbl.add attrs "block/title" ();
  List.iter (function Query_block.Cells _ -> () | Query_block.Block block ->
    Seq.iter (fun (d : Ds.datom) -> if public_attr d.a then Hashtbl.replace attrs d.a ())
      (Ds.Db.datoms db Ds.Eavt ~e:(eid db block.uuid) ())) rows;
  List.iter (fun attr -> if public_attr attr then Hashtbl.replace attrs attr ()) ordered;
  let hidden = match view with None -> [] | Some id -> attr_values db id "logseq.property.table/hidden-columns" in
  let rest = Hashtbl.fold (fun attr () acc -> if List.mem attr ordered then acc else attr :: acc) attrs [] |> List.sort String.compare in
  List.filter (fun attr -> public_attr attr && not (List.mem (key attr) hidden))
    (if ordered = [] then "block/title" :: List.filter (( <> ) "block/title") rest else ordered @ rest)
  |> List.map (property db)
let editable_type p = List.mem p.typ ["default"; "url"; "number"; "checkbox"; "date"; "datetime"; "page"; "entity"; "node"; "class"; "property"]
let editable p = p.attr = "block/title" || (public_attr p.attr
  && not (List.mem p.attr ["block/created-at"; "block/updated-at"])
  && editable_type p)
let node_editable db p = p.attr = "block/title" || p.attr = "block/tags" || editable p || (editable_type p && String.starts_with ~prefix:"logseq.property/" p.attr
  && match attr_eid db p.attr with None -> false | Some id ->
    get db id "logseq.property/hide?" <> Ds.Bool true && get db id "logseq.property/public?" <> Ds.Bool false)
let choices_json db choices =
  `List (List.map (fun id -> `Assoc ["uuid", `String (uuid db id);
    "title", `String (display (content db (Ds.Ref id)))]) choices)
let title_editor_value db source =
  let label tag uuid =
    Option.bind (Ds.entid db "block/uuid" (Ds.Uuid uuid)) (fun id ->
      Option.bind (G.entity_title (fun value -> Ok value) db id) (fun title ->
        if G.unique_named_uuid tag db title = Some uuid then Some title else None)) in
  Ref_text.to_text (label true) (label false) source
let property_metadata db attr =
  let p = property db attr in
  `Assoc ["attr", `String attr; "title", `String p.title; "editable", `Bool (node_editable db p)]
let reference_predicate db p =
  let classes = List.concat_map (G.class_descendants db) p.classes |> List.sort_uniq compare in
  fun id ->
    not (G.page_is_hidden db id) &&
    (classes = [] || List.exists (fun tag -> List.mem tag classes) (G.ref_eids db id "block/tags")) &&
    (match p.typ with
     | "page" -> Node_title.is_page db id
     | "class" -> G.entity_is_instance_of db id "logseq.class/Tag"
     | "property" -> Node_title.is_property db id
     | "node" | "entity" -> get db id "logseq.property/created-from-property" = Ds.Nil
       && get db id "block/closed-value-property" = Ds.Nil
     | _ -> true)
let reference_candidates db p =
  if p.closed || not (List.mem p.typ ["node"; "entity"; "page"; "class"; "property"]) then [] else
  let accepts = reference_predicate db p in
  let classes = match p.classes, p.typ with
    | [], "class" -> Option.to_list (attr_eid db "logseq.class/Tag")
    | [], "property" -> Option.to_list (attr_eid db "logseq.class/Property")
    | classes, _ -> classes in
  let ids = match classes with
    | [] -> Ds.Db.datoms db Ds.Aevt ~a:(if p.typ = "page" then "block/name" else "block/uuid") ()
      |> Seq.map (fun (d : Ds.datom) -> d.e) |> List.of_seq
    | classes -> List.concat_map (G.class_descendants db) classes |> List.sort_uniq compare
      |> List.concat_map (fun id -> Datascript_value.datoms_by_ref db Ds.Aevt "block/tags" id
        |> Seq.map (fun (d : Ds.datom) -> d.e) |> List.of_seq) |> List.sort_uniq compare in
  List.filter_map (fun id ->
    if accepts id && String.trim (display (get db id "block/title")) <> ""
      && (p.typ <> "class" || G.tag_available_for_completion db id)
    then Some (Ds.Ref id) else None) ids
let property_references db p assigned =
  if not (List.mem p.typ ["page"; "node"; "entity"; "class"; "property"; "date"]) then [] else
  List.filter_map (fun value -> Option.bind (node_target_id db p value) (fun id ->
    if empty db value || G.page_is_hidden db id then None else
    Option.map (fun (node : Cache_model.entity_summary) ->
      `Assoc ["uuid", `String node.uuid; "title", `String node.title])
      (G.entity_summary (fun value -> Ok value) db id))) assigned
let scoped_reference_values db p values =
  if p.closed || not (List.mem p.typ ["node"; "entity"; "page"; "class"; "property"]) then values
  else
    let accepts = reference_predicate db p in
    List.filter (fun value -> Option.fold ~none:false ~some:accepts (node_target_id db p value)) values
let column_json ?(include_candidates = true) db rows p =
  let values = (if p.typ = "checkbox" then [Ds.Bool false; Ds.Bool true] else
    List.map (fun id -> Ds.Ref id) p.choices @
    (if include_candidates then reference_candidates db p else []) @
    List.concat_map (function Query_block.Cells _ -> [] | Query_block.Block block ->
      attr_values db (eid db block.uuid) p.attr) rows) |> scoped_reference_values db p |> List.sort_uniq compare in
  let filter_values = List.map (fun value ->
    let match_value = match value with Ds.Bool value -> `Bool value
      | Ds.Ref id -> `List [`String (uuid db id)] | _ -> `List [plain value] in
    `Assoc ["title", `String (property_display db p value); "match", match_value;
      "value", plain value;
      "journalDay", (match ref_id db value with Some id -> plain (get db id "block/journal-day") | None -> `Null)]) values in
  `Assoc ["attr", `String p.attr; "title", `String p.title; "kind", `String p.typ;
  "many", `Bool p.many; "ref", `Bool p.ref_; "editable", `Bool (editable p);
  "filterTimestamp", `Bool (List.mem p.attr ["block/created-at"; "block/updated-at"]);
  "filterOperators", `List (List.map (fun op -> `String op)
    (if List.mem p.attr ["block/created-at"; "block/updated-at"] then ["before"; "after"]
     else ["is"; "is-not"] @ (match p.typ with
       | "datetime" -> ["before"; "after"]
       | "default" | "url" | "node" | "string" -> ["text-contains"; "text-not-contains"]
       | "date" -> ["date-before"; "date-after"]
       | "number" -> ["number-gt"; "number-lt"; "number-gte"; "number-lte"; "between"]
       | _ -> [])));
  "closed", `Bool p.closed;
  "canCreate", `Bool (not p.closed && p.typ <> "checkbox" && p.typ <> "property");
  "filterValues", `List filter_values;
  "choices", choices_json db p.choices]
let row_json db encode properties = function
  | Query_block.Cells cells -> `Assoc ["cells", `List (List.map (fun cell -> `String cell) cells)]
  | Query_block.Block block -> let id = eid db block.uuid in
    `Assoc ["block", encode block; "properties", `List (List.map (fun p ->
      let editor = if p.closed then
        let choices = G.scope_closed_value_eids db ~owner:id p.choices in
        if choices = p.choices then [] else
          ["choices", choices_json db choices; "closed", `Bool true; "canCreate", `Bool false]
        else [] in
      `Assoc (editor @ ["attr", `String p.attr; "kind", `String p.typ; "editable", `Bool (editable p && (p.attr <> "block/title" || Node_title.can_edit db id));
        "text", `String (String.concat ", " (List.map (property_display db p) (attr_values db id p.attr)));
        "editorValue", `String (match attr_values db id p.attr with
          | value :: _ when p.attr = "block/title" -> title_editor_value db (display value)
          | value :: _ -> temporal_value db p value | [] -> "");
        "references", `List (property_references db p (attr_values db id p.attr));
        "raw", semantic_json db (raw db id p.attr)])) properties)]
let render_rows ?(input = "") db ~owner ~feature ~encode_block rows =
  let views = saved_views db owner feature in
  let views = if views = [] then [None] else List.map Option.some views in
  let original_rows = rows in
  let view_json view =
    let id = Option.fold ~none:(owner ^ ":default") ~some:(uuid db) view in
    let setting attr = Option.fold ~none:Ds.Nil ~some:(fun id -> get db id attr) view in
    let name = Option.fold ~none:"All" ~some:(fun id -> display (get db id "block/title")) view in
    let typ = match Option.bind (ref_id db (setting "logseq.property.view/type")) (fun id -> Some (ident db id)) with
      | Some "logseq.property.view/type.table" -> "table" | Some "logseq.property.view/type.gallery" -> "gallery"
      | Some "logseq.property.view/type.list" | None -> "list" | _ -> "invalid" in
    let fields = ["uuid", `String id; "name", `String name; "type", `String typ;
      "persisted", `Bool (view <> None); "sorting", plain (setting "logseq.property.table/sorting");
      "filters", plain (setting "logseq.property.table/filters")] in
    try
      if typ = "invalid" then invalid_arg "Unsupported view type";
      let rows = apply_view db feature (setting "logseq.property.table/sorting")
          (setting "logseq.property.table/filters") input rows in
      let properties = columns db view original_rows in
      let properties = if typ <> "table" then properties else
        let visible = List.filter (fun p -> p.attr <> "block/updated-at") properties in
        let ordinary, created = List.partition (fun p -> p.attr <> "block/created-at") visible in
        ordinary @ created in
      let available = columns db None original_rows in
      let known = Ds.Db.datoms db Ds.Aevt ~a:"db/ident" ()
        |> Seq.filter_map (fun (d : Ds.datom) -> match d.v with
          | Ds.Keyword attr when public_attr attr -> Some attr | _ -> None) |> List.of_seq in
      let catalog = List.sort_uniq String.compare (known @ List.map (fun p -> p.attr) available)
        |> List.map (property db) in
      let cell_properties = if typ = "list" then [] else properties in
      `Assoc (fields @ ["error", `Null; "columns", `List (List.map (column_json ~include_candidates:(typ <> "list") db original_rows) properties);
        "properties", `List (List.map (column_json ~include_candidates:(typ <> "list") db original_rows) catalog);
        "rows", `List (List.map (row_json db encode_block cell_properties) rows)])
    with error -> `Assoc (fields @ ["error", `String (match error with Invalid_argument message -> message | _ -> Printexc.to_string error);
      "rows", `List []; "columns", `List []]) in
  `Assoc ["ownerUuid", `String owner; "featureType", `String feature; "views", `List (List.map view_json views)]

let scope db owner feature = match feature with
  | "query-result" -> (match Query_block.render db owner with Some result -> result.rows | None -> invalid_arg "This object has no query")
  | "class-objects" -> List.map (fun block -> Query_block.Block block) (G.objects_for_tag (fun text -> Ok text) db owner)
  | "property-objects" ->
    let attr = ident db (eid db owner) in
    if attr = "" then invalid_arg "This object is not a property";
    Dev_view.property_object_eids db attr
    |> List.filter_map (fun id -> if G.page_is_hidden db id || get db id "logseq.property/created-from-property" <> Ds.Nil
      || get db id "block/closed-value-property" <> Ds.Nil then None
      else Option.map (fun block -> Query_block.Block block)
        (match G.page_block (fun text -> Ok text) db id with Some _ as block -> block
         | None -> G.block ~with_breadcrumbs:true (fun text -> Ok text) db id))
  | _ -> invalid_arg "Views are only available for queries, tag objects, and property objects"
let render ?input db ~owner ~feature ~encode_block =
  try Ok (render_rows ?input db ~owner ~feature ~encode_block (scope db owner feature))
  with error -> Error (match error with Invalid_argument message -> message | _ -> Printexc.to_string error)

let is_uuid value = String.length value = 36 && value.[8] = '-' && value.[13] = '-'
  && value.[18] = '-' && value.[23] = '-'
let rec config_value = function
  | `Null -> Ds.Nil | `Bool b -> Ds.Bool b | `Int n -> Ds.Int64 (Int64.of_int n)
  | `Float f when Float.is_finite f -> Ds.Float f
  | `String value -> if is_uuid value then Ds.Uuid value else Ds.String value
  | `List values -> Ds.Vector (List.map config_value values)
  | `Assoc fields -> Ds.Map (List.map (fun (key, value) -> Ds.Keyword key, config_value value) fields)
  | _ -> invalid_arg "Invalid view setting"
let filter_match operator value = match operator, value with
  | ("is" | "is-not"), `String "empty" -> Ds.Keyword "empty"
  | ("is" | "is-not"), `List values -> Ds.Set (List.map config_value values)
  | _ -> config_value value
let config_settings config =
  let fields = match config with `Assoc fields -> fields | _ -> invalid_arg "View configuration must be an object" in
  List.filter_map (fun (name, value) -> match name, value with
    | "type", `String ("list" | "table" | "gallery" as typ) ->
      Some ("logseq.property.view/type", Ops.Ref_ident ("logseq.property.view/type." ^ typ))
    | "sorting", `List keys ->
      let keys = List.map (fun key -> Ds.Map [Ds.Keyword "id", Ds.Keyword (required "id" key);
        Ds.Keyword "asc?", (match member "asc" key with `Bool asc -> Ds.Bool asc | _ -> invalid_arg "Sort direction is required")]) keys in
      Some ("logseq.property.table/sorting", semantic (Ds.empty_db ()) (Ds.Vector keys))
    | "filters", (`Assoc _ as filters) ->
      let clauses = match member "clauses" filters with `List clauses -> clauses | _ -> invalid_arg "Filter clauses are required" in
      let clauses = List.map (function
        | `List [`String attr; `String operator; value] ->
          Ds.Vector [Ds.Keyword attr; Ds.Keyword operator; filter_match operator value]
        | _ -> invalid_arg "Invalid filter clause") clauses in
      let or_ = match member "or" filters with `Bool b -> b | _ -> invalid_arg "Filter match mode is required" in
      Some ("logseq.property.table/filters", semantic (Ds.empty_db ())
        (Ds.Map [Ds.Keyword "or?", Ds.Bool or_; Ds.Keyword "filters", Ds.Vector clauses]))
    | "orderedColumns", `List columns -> Some ("logseq.property.table/ordered-columns",
        Ops.Vector_value (List.map (function `String attr when public_attr attr -> Ops.Keyword_value attr
          | _ -> invalid_arg "Invalid column") columns))
    | "hiddenColumns", `List columns -> Some ("logseq.property.table/hidden-columns",
        Ops.Set_value (List.map (function `String attr when public_attr attr -> Ops.Keyword_value attr
          | _ -> invalid_arg "Invalid column") columns))
    | "name", `String name when String.trim name <> "" -> None
    | _ -> invalid_arg ("Invalid view setting: " ^ name)) fields
let property_change db uuid (attr, value) =
  {Ops.attr; expected = Option.map (semantic db) (raw db (eid db uuid) attr); value = Some value}
let numeric text = match float_of_string_opt text with
  | Some value when Float.is_finite value ->
    if Float.is_integer value && value < float_of_int max_int && value > float_of_int min_int
    then Ops.Int_value (int_of_float value) else Ops.Float_value value
  | _ -> invalid_arg "Enter a valid number"
let calendar_day text =
  let digits text = String.for_all (fun c -> c >= '0' && c <= '9') text in
  let compact = if String.length text = 10 && text.[4] = '-' && text.[7] = '-' then
      String.sub text 0 4 ^ String.sub text 5 2 ^ String.sub text 8 2
    else text in
  if String.length compact <> 8 || not (digits compact) then None
  else let day = int_of_string compact in
    if day / 10000 < 1 || Dev_query.Time.local_date_of_journal_day (Dev_query.Time.local_tz ()) day = None
    then invalid_arg "Enter a valid calendar date";
    Some day
let resolve_reference db p value =
  let resolved id =
    let valid = p.closed || match p.typ with
      | "number" | "datetime" -> Option.is_some (number (content db (Ds.Ref id)))
      | "date" -> get db id "block/journal-day" <> Ds.Nil
      | "page" -> Node_title.is_page db id
      | "class" -> G.entity_is_instance_of db id "logseq.class/Tag"
      | "property" -> G.entity_is_instance_of db id "logseq.class/Property"
      | _ -> true in
    if not valid || (not p.closed && not (reference_predicate db p id)) then
      invalid_arg "Choose a value of this property's type and configured tags";
    semantic db (Ds.Ref id)
  in
  let matching = if p.closed then p.choices else
    Ds.Db.datoms db Ds.Avet ~a:"block/title" ~v:(Ds.String value) ()
      |> Seq.map (fun (d : Ds.datom) -> d.e) |> List.of_seq in
  let matching = List.find_opt (fun id -> uuid db id = value || display (content db (Ds.Ref id)) = value) matching in
  match matching with
  | Some id -> resolved id
  | None when is_uuid value ->
    let id = eid db value in
    if p.closed && not (List.mem id p.choices) then invalid_arg "Choose one of the property's values";
    resolved id
  | None -> invalid_arg "Choose an existing object"
let edit_property ?(text_value = false) ?(allow_builtin = false) db ~now ~fresh_uuid json =
  let target = required "blockUuid" json and attr = required "attr" json in
  let target_id = eid db target in
  let p = property ~owner:target_id db attr in
  if not ((if allow_builtin then node_editable db else editable) p) then invalid_arg "This property is read-only";
  let expected = member "expected" json in
  if expected <> semantic_json db (raw db target_id attr) then invalid_arg "This cell changed. Reopen it to edit the latest value";
  let text = match member "value" json with `String value -> value | _ -> invalid_arg "A cell value is required" in
  if attr = "block/title" then (
    (match Node_title.validate db target_id text with Ok () -> () | Error message -> invalid_arg message);
    Ops.Save_title {uuid = target; expected_title = display (get db target_id attr); title = text})
  else
    let created = ref [] in
    let value text =
      if p.closed then resolve_reference db p text
      else if p.typ = "checkbox" then (match String.lowercase_ascii text with
        | "true" -> Ops.Bool_value true | "false" -> Ops.Bool_value false
        | _ -> invalid_arg "Choose true or false")
      else if p.typ = "date" then (match calendar_day text with
        | None -> resolve_reference db p text
        | Some day ->
          (match Seq.uncons (Ds.Db.datoms db Ds.Avet ~a:"block/journal-day" ~v:(Ds.Int64 (Int64.of_int day)) ()) with
           | Some (d, _) -> semantic db (Ds.Ref d.e)
           | None ->
             let uuid = Rpc_wire.journal_page_uuid day in
             created := Ops.Create_journal {page_uuid = uuid; block_uuid = fresh_uuid (); block_title = "";
               title = Journal.title db day; journal_day = day; created_at = now} :: !created;
             Ops.Ref_uuid uuid))
      else if List.mem p.typ ["number"; "datetime"; "default"; "url"] then
        let content = if p.typ = "number" || p.typ = "datetime" then numeric text else Ops.String_value text in
        if p.ref_ then (
          let uuid = fresh_uuid () in
          created := Ops.Create_property_value {uuid; owner_uuid = target; property_ident = attr; content; created_at = now} :: !created;
          Ops.Ref_uuid uuid)
        else content
      else if member "create" json = `Bool true && List.mem p.typ ["page"; "node"; "entity"; "class"] then
        (try resolve_reference db p text with Invalid_argument message ->
          if is_uuid text || Seq.uncons (Ds.Db.datoms db Ds.Avet ~a:"block/title" ~v:(Ds.String text) ()) <> None
          then invalid_arg message;
          let uuid = fresh_uuid () in
          let page = {Ops.uuid; title = text; created_at = now} in
          let tags = List.filter_map (fun id -> let tag_uuid = Option.value ~default:"" (G.uuid_for_eid db id) in
            if tag_uuid = "" then None else Some (Ops.Add_tag {uuid = page.uuid; tag_uuid})) p.classes in
          let create = if p.typ = "class" then Ops.Create_tag page else Ops.Create_page page in
          created := List.rev_append (create :: tags) !created;
          Ops.Ref_uuid uuid)
      else resolve_reference db p text in
    let assigned = if text_value && p.many && List.mem p.typ ["default"; "url"] && not p.closed then (
      let previous = List.map (semantic db) (attr_values db target_id attr) in
      let replaced = match member "textValueUuid" json with
        | `Null -> None
        | `String uuid when List.mem (Ops.Ref_uuid uuid) previous -> Some (Ops.Ref_uuid uuid)
        | _ -> invalid_arg "This text value no longer belongs to the object" in
      let remaining = List.filter (fun value -> Some value <> replaced) previous in
      let next = if String.trim text = "" then remaining else remaining @ [value text] in
      match next with [] -> None | values -> Some (Ops.Set_value values))
    else match member "selectedValues" json with
      | `List selected ->
        if not p.ref_ then invalid_arg "This property does not accept object references";
        if not p.many && List.length selected > 1 then invalid_arg "Choose a single value";
        let selected = List.map (function
          | `String uuid when is_uuid uuid -> resolve_reference db p uuid
          | _ -> invalid_arg "Choose an existing value") selected in
        let selected = selected @ (match member "newValues" json with
          | `Null -> []
          | `List values when p.many && member "create" json = `Bool true -> List.map (function
              | `String text when String.trim text <> "" -> value (String.trim text)
              | _ -> invalid_arg "Enter a value") values
          | _ -> invalid_arg "Invalid new values") in
        (match selected with [] -> None | [value] when not p.many -> Some value
         | values -> Some (Ops.Set_value values))
      | `Null -> if String.trim text = "" then None else
      Some (if p.many then Ops.Set_value (List.map (fun text -> value (String.trim text)) (String.split_on_char ',' text))
        else value text)
      | _ -> invalid_arg "Invalid selected values" in
    let intent = Ops.Set_property {uuid = target; attr; expected = Option.map (semantic db) (raw db target_id attr); value = assigned} in
    if !created = [] then intent else Ops.Atomic (List.rev !created @ [intent])
let edit_cell db ~now ~fresh_uuid owner feature _view json =
  let target = required "blockUuid" json in
  if not (List.exists (function Query_block.Block block -> block.uuid = target | _ -> false) (scope db owner feature))
  then invalid_arg "This object is no longer in the view";
  edit_property db ~now ~fresh_uuid json

let property_json ?(include_candidates = true) db ~owner ~attr ~encode_block =
  let id = eid db owner in
  let p = property ~owner:id db attr in
  let assigned = attr_values db id attr in
  let text_layout = List.mem p.typ ["default"; "url"] && not p.closed in
  let blocks = if not text_layout then [] else List.filter_map (fun value ->
    Option.bind (ref_id db value) (fun id -> Option.map encode_block
      (G.block (fun value -> Ok value) db id))) assigned in
  let references = property_references db p assigned in
  let metadata = match column_json ~include_candidates:false db [] p with `Assoc fields -> fields | _ -> [] in
  let text = String.concat ", " (List.map (property_display db p) assigned) in
  let candidates = if text_layout || not include_candidates then [] else
    if not p.closed && List.mem p.typ ["node"; "entity"; "page"; "class"; "property"] then reference_candidates db p
    else
    Ds.Db.datoms db Ds.Aevt ~a:attr () |> Seq.map (fun (d : Ds.datom) -> d.v) |> List.of_seq in
  let candidates = scoped_reference_values db p (assigned @ candidates) |> List.sort_uniq compare in
  let filter_values = List.map (fun value -> `Assoc [
    "title", `String (property_display db p value); "value", plain value;
    "match", (match ref_id db value with Some id -> `List [`String (uuid db id)] | None -> `List [plain value])]) candidates in
  `Assoc (("editorValue", `String (match assigned with
      | value :: _ when attr = "block/title" -> title_editor_value db (display value)
      | value :: _ -> temporal_value db p value | [] -> "")) ::
    ("text", `String text) :: ("raw", semantic_json db (raw db id attr)) ::
    ("textLayout", `Bool text_layout) :: ("blocks", `List blocks) ::
    ("references", `List references) ::
    ("markup", Markup.to_yojson (Markup.parse [] [] text)) ::
    ("filterValues", `List filter_values) :: ("editable", `Bool (node_editable db p && (p.attr <> "block/title" || Node_title.can_edit db id))) ::
    List.remove_assoc "editable" (List.remove_assoc "filterValues" metadata))
let mutation db ~now ~fresh_uuid json =
  try
    let owner = required "ownerUuid" json and feature = required "featureType" json in
    let _ = scope db owner feature in
    let view = text (member "viewUuid" json) and action = required "action" json in
    let creating = action = "create" || view = owner ^ ":default" in
    if not creating && not (List.mem (eid db view) (saved_views db owner feature)) then
      invalid_arg "This view no longer belongs to the object";
    if action = "editCell" then Ok (edit_cell db ~now ~fresh_uuid owner feature view json)
    else if action <> "save" && action <> "create" then Error "Unknown view action"
    else
      let config = member "config" json in
      let settings = config_settings config in
      let name = match member "name" config with `String value when String.trim value <> "" -> String.trim value
        | _ -> if creating then "New view" else display (get db (eid db view) "block/title") in
      if creating then (
        let page, create_page = match Seq.uncons (Ds.Db.datoms db Ds.Avet ~a:"block/name" ~v:(Ds.String "$$$views") ()) with
          | Some (d, _) -> uuid db d.e, []
          | None -> let uuid = fresh_uuid () in uuid, [Ops.Create_page {uuid; title = "$$$views"; created_at = now}] in
        let view = fresh_uuid () in
        let last_order = match Ds.entid db "block/uuid" (Ds.Uuid page) with
          | None -> None
          | Some page_id -> Ds.Db.datoms db Ds.Aevt ~a:"block/page" ~v:(Ds.Ref page_id) ()
            |> Seq.filter_map (fun (d : Ds.datom) -> match get db d.e "block/order" with Ds.String value -> Some value | _ -> None)
            |> Seq.fold_left (fun current value -> Some (Option.fold ~none:value ~some:(fun current -> max current value) current)) None in
        let order = Result.get_ok (Fractional_order.between last_order None) in
        let defaults = ["logseq.property/view-for", Ops.Ref_uuid owner;
          "logseq.property.view/feature-type", Ops.Keyword_value feature;
          "logseq.property.view/type", Ops.Ref_ident "logseq.property.view/type.list"] in
        let settings = List.filter (fun (attr, _) -> not (List.mem_assoc attr settings)) defaults @ settings in
        Ok (Ops.Atomic (create_page @ [Ops.Insert_block {uuid = view; title = name; page_uuid = page;
          parent_uuid = page; order; created_at = now}; Ops.Set_properties {uuid = view;
            changes = List.map (fun (attr, value) -> {Ops.attr; expected = None; value = Some value}) settings}]))
      ) else
        let title = display (get db (eid db view) "block/title") in
        let intents = (if title = name then [] else [Ops.Save_title {uuid = view; expected_title = title; title = name}])
          @ (if settings = [] then [] else [Ops.Set_properties {uuid = view; changes = List.map (property_change db view) settings}]) in
        match intents with [] -> Error "No view settings changed" | [intent] -> Ok intent | intents -> Ok (Ops.Atomic intents)
  with error -> Error (match error with Invalid_argument message -> message | _ -> Printexc.to_string error)
