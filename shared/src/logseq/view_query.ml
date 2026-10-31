open Lui_elements

module Expanded = Set.Make (String)
type block = {row : Model.outline_row; children : block list}
type item = {index : int; uuid : string option; title : string; block : block option; json : Yojson.Basic.t}
type query = {rows : item list; error : string option; source : string}

let member name = function `Assoc fields -> List.assoc_opt name fields | _ -> None
let string = function Some (`String text) -> text | _ -> ""
let rec decode_block depth json =
  if depth > 128 then invalid_arg "Result block nesting is too deep";
  match Response_snapshot.related_row json with
  | None -> invalid_arg "Invalid result block"
  | Some row ->
    let children = match member "children" json with
      | Some (`List children) -> List.map (decode_block (depth + 1)) children
      | _ -> [] in
    {row = {row with Model.query_json = ""; has_children = children <> [];
      is_collapsed = children <> []}; children}
let invalid_query = {rows = []; error = Some "Unable to display query results"; source = ""}
let decode_json json =
  try
    let rows = match member "rows" json with Some (`List rows) -> rows | _ -> [] in
    {source = string (member "source" json);
     error = (match member "error" json with Some (`String text) -> Some text | _ -> None);
     rows = List.mapi (fun index json -> match member "block" json with
       | Some block_json -> let block = decode_block 0 block_json in {
           index; uuid = Some block.row.row_uuid;
           title = (match member "displayTitle" block_json with Some (`String title) -> title | _ -> block.row.row_title);
           block = Some block; json}
       | None -> let cells = match member "cells" json with Some (`List xs) -> xs | _ -> [] in
         {index; uuid = None; title = String.concat "  ·  " (List.map (fun value -> string (Some value)) cells);
          block = None; json}) rows}
  with _ -> invalid_query
let decode raw = try decode_json (Yojson.Basic.from_string raw) with _ -> invalid_query

let result_item owner render_block send source : t =
 fun context parent ->
  let initial = Signal.sample source in
  let expanded = Signal.state context.ui_scheduler Expanded.empty in
  let rows = Signal.own_signal context.ui_scope (Signal.map2 (fun item expanded ->
    let rec collect depth block acc =
      let row = {block.row with Model.depth;
        is_collapsed = block.children <> [] && not (Expanded.mem block.row.row_uuid expanded);
        row_breadcrumbs = (if depth = 0 then block.row.row_breadcrumbs else []);
        row_breadcrumb = (if depth = 0 then block.row.row_breadcrumb else "")} in
      let acc = row :: acc in
      if row.is_collapsed then acc else List.fold_left (fun acc child -> collect (depth + 1) child acc) acc block.children in
    match item.block with None -> [] | Some block -> List.rev (collect 0 block [])) source (Signal.value expanded)) in
  let send = function
    | Model.ToggleOutlinerCollapsed uuid ->
      let current = Signal.sample (Signal.value expanded) in
      Signal.set expanded (if Expanded.mem uuid current then Expanded.remove uuid current else Expanded.add uuid current);
      true
    | action -> send action in
  let identifier = "query.result." ^ owner ^ "." ^ string_of_int initial.index in
  (box ~padding:0 ~accessibility_identifier:identifier [
    (match initial.block with
     | Some _ -> keyed ~source:rows ~key:(fun row -> row.Model.row_uuid) ~cmp:String.compare
         ~mount:(fun source -> render_block source send)
     | None -> text ~value_signal:(Signal.map (fun item -> item.title) source) ~text_alignment:`start [])]) context parent

let results_disclosure context identifier expanded label =
  let size = if Lui_ui.host context = KotlinHost then 24 else 10 in
  row ~gap:8 ~cross:`center [
    icon ~name_signal:(Signal.map (fun expanded ->
      `app (if expanded then "disclosure-down" else "disclosure-right")) expanded)
      ~width:size ~height:size ~foreground:"muted-foreground"
      ~accessibility_identifier:identifier [];
    text ~value_signal:label [];
  ]

let legacy_view ~render_block model_source row_source send : t =
 fun context parent ->
  let owner = (Signal.sample row_source).Model.row_uuid in
  let identifier name = "query." ^ name ^ "." ^ owner in
  let own source = Signal.own_signal context.Lui_ui.ui_scope source in
  let raw = own (Signal.cutoff String.equal (own (Signal.map (fun row -> row.Model.query_json) row_source))) in
  let query = own (Signal.map decode raw) in
  let expanded = Signal.state context.ui_scheduler true in
  let limit = Signal.state context.ui_scheduler 20 in
  let entries = own (Signal.map2 (fun query count ->
    let rec take acc count = function
      | _ when count <= 0 -> List.rev acc | [] -> List.rev acc
      | row :: rest -> take (row :: acc) (count - 1) rest in
    take [] count query.rows) query (Signal.value limit)) in
  let visible = own (Signal.map (fun row -> row.Model.query_json <> "" && not row.is_collapsed) row_source) in
  (if_ ~test:visible
    (box ~padding_horizontal:16 ~padding_vertical:8
      ~accessibility_identifier:(identifier "block")
      [column ~gap:4 [
        button ~variant:`ghost ~text_alignment:`start ~min_height:44
          ~label:(View_base.tr (Signal.sample model_source) "Toggle query results") ~accessibility_identifier:(identifier "toggle")
          ~on_press:(fun _ -> Signal.set expanded (not (Signal.sample (Signal.value expanded))))
          [results_disclosure context (identifier "disclosure") (Signal.value expanded)
            (own (Signal.map (fun query -> string_of_int (List.length query.rows) ^ " results") query))];
        if_ ~test:(Signal.value expanded)
          (column ~gap:4 ~accessibility_identifier:(identifier "rows") [

            if_ ~test:(own (Signal.map (fun query -> query.error = None && query.rows = []) query))
              (text ~value_signal:(own (Signal.map (fun query ->
                if String.trim query.source = "" then "No query defined" else "No results") query))
                ~foreground:"muted-foreground" ~accessibility_identifier:(identifier "empty") []);
            keyed ~source:entries ~key:(fun row -> Option.value ~default:"cell" row.uuid ^ ":" ^ string_of_int row.index)
              ~cmp:String.compare ~mount:(fun source -> result_item owner render_block send source);
            if_ ~test:(own (Signal.map2 (fun query limit -> List.length query.rows > limit) query (Signal.value limit)))
              (button ~variant:`ghost ~text:(View_base.tr (Signal.sample model_source) "Show more") ~accessibility_identifier:(identifier "more")
                ~on_press:(fun _ -> Signal.set limit (Signal.sample (Signal.value limit) + 20)) []);
          ]);
      ]])) context parent

let block_values ~render_block owner source send =
  let render_block source send =
    render_block (Signal.map (fun row -> {row with Model.row_breadcrumb = ""; row_breadcrumbs = []}) source) send in
  let rows = Signal.map (fun json -> (decode_json (`Assoc [
    "rows", `List (match json with `List blocks -> List.map (fun block -> `Assoc ["block", block]) blocks | _ -> [])])).rows) source in
  keyed ~source:rows ~key:(fun item -> Option.value ~default:"" item.uuid) ~cmp:String.compare
    ~mount:(result_item owner render_block send)


module Json = Yojson.Basic
let jfield name json = Option.value ~default:`Null (member name json)
let jtext json = string (Some json)
let property_title current property = View_base.property_title current
  ~attr:(jtext (jfield "attr" property)) ~title:(jtext (jfield "title" property))
let jlist = function `List values -> values | _ -> []
let jbool = function `Bool value -> value | _ -> false
let jint = function `Int value -> value | _ -> 0
let items json =
  let offset = jint (jfield "rowOffset" json) in
  List.map (fun item -> {item with index = item.index + offset}) (decode_json json).rows
let row_count json = match jfield "rowCount" json with `Int count -> count | _ -> List.length (jlist (jfield "rows" json))
let text_value = function
  | `String value -> value | `Int value -> string_of_int value | `Float value -> string_of_float value
  | `Bool value -> string_of_bool value | `Null -> "" | value -> Json.to_string value
let fields json = match json with `Assoc fields -> fields | _ -> []
let csv value = String.split_on_char ',' value |> List.map String.trim |> List.filter ((<>) "")
let input_value = function `List values -> String.concat ", " (List.map text_value values)
  | `Assoc fields -> (match List.assoc_opt "block/journal-day" fields with
      | Some (`Int day) -> Printf.sprintf "%04d-%02d-%02d" (day / 10000) (day / 100 mod 100) (day mod 100)
      | _ -> "")
  | value -> text_value value
let local_input set = function Lui_protocol.TextChanged (_, value) -> set value | _ -> ()
let list_take count values = List.filteri (fun index _ -> index < count) values

type saved_view = {id : string; name : string; typ : string; data : Json.t}
let saved_views_json json =
  try json |> jfield "views" |> jlist |> List.mapi (fun index data ->
    let id = jtext (jfield "uuid" data) in
    {id = (if id = "" then "invalid." ^ string_of_int index else id);
     name = jtext (jfield "name" data); typ = jtext (jfield "type" data); data})
  with _ -> []
let saved_views raw = try saved_views_json (Json.from_string raw) with _ -> []
let operator_title = function
  | "is" -> "Is" | "is-not" -> "Is not" | "text-contains" -> "Contains"
  | "text-not-contains" -> "Does not contain" | "number-gt" -> "Greater than"
  | "number-gte" -> "At least" | "number-lt" -> "Less than" | "number-lte" -> "At most"
  | "between" -> "Between" | "date-before" | "before" -> "Before"
  | "date-after" | "after" -> "After" | value -> value
let operators col = jlist (jfield "filterOperators" col) |> List.map jtext
let choices view = jlist (jfield "columns" view.data)
let property_choices view = match jlist (jfield "properties" view.data) with [] -> choices view | values -> values
let view_column view attr = Option.value ~default:(`Assoc ["attr", `String attr; "title", `String attr; "kind", `String "default"])
    (List.find_opt (fun value -> jfield "attr" value = `String attr) (property_choices view))
let payload owner feature view action extra =
  Json.to_string (`Assoc (["ownerUuid", `String owner; "featureType", `String feature;
    "viewUuid", `String view; "action", `String action] @ extra))
let feedback source id = Signal.map (fun (model : Model.logseq_model) ->
  List.find_opt (fun (view, _, _) -> view = id) model.result_view_feedback) source
let waiting source id = Signal.map (fun (model : Model.logseq_model) ->
  List.exists (function Model.LoadPropertyValuesEffect (_, view, _) | Model.ResultViewEffect (_, view, _) | Model.NodePropertyEffect (_, view, _) -> view = id | _ -> false)
    (model.pending_effects @ model.in_flight_effects)) source
let loaded_column context ~id ~owner ~mode ~feature column model_source send =
  let own signal = Signal.own_signal context.Lui_ui.ui_scope signal in
  let current = Signal.sample model_source in
  let graph = current.Model.selected_graph_id in
  let prefix = Option.value ~default:"local" graph ^ ":" ^ owner ^ ":" ^ mode ^ ":" ^ id
    ^ ":" ^ string_of_int current.next_effect_id in
  let request = own (Signal.cutoff (=) (own (Signal.map (fun col ->
    jtext (jfield "attr" col), jfield "valuesDeferred" col = `Bool true) column))) in
  let requested = ref None in
  let load (attr, deferred) =
    let key = prefix ^ ":" ^ attr in
    if deferred && !requested <> Some key then (
      requested := Some key;
      ignore (send (Model.LoadPropertyValues (key, Json.to_string (`Assoc ([
        "key", `String key; "ownerUuid", `String owner; "attr", `String attr;
        "mode", `String mode; "featureType", `String feature] @
        Option.fold ~none:[] ~some:(fun graph -> ["graphId", `String graph]) graph)))))) in
  ignore (Signal.own context.ui_scope (Signal.observe request load));
  load (Signal.sample request);
  let received = own (Signal.cutoff (=) (own (Signal.map2 (fun (attr, deferred) (model : Model.logseq_model) ->
    let key = prefix ^ ":" ^ attr in
    key, if deferred then List.assoc_opt key model.property_value_catalogs else None) request model_source))) in
  let catalog = Signal.state context.ui_scheduler None in
  let catalog_key = ref "" in
  let receive (key, values) =
    if key <> !catalog_key || values <> None then Signal.set catalog values;
    catalog_key := key in
  ignore (Signal.own context.ui_scope (Signal.observe received receive));
  receive (Signal.sample received);
  let catalog = Signal.value catalog in
  let loaded = own (Signal.map2 (fun col raw -> match raw with
    | Some raw -> (try Json.from_string raw with _ -> col) | None -> col) column catalog) in
  let error = own (Signal.map2 (fun (attr, _) (model : Model.logseq_model) ->
    match List.find_opt (fun (key, _, _) -> key = prefix ^ ":" ^ attr) model.result_view_feedback with
    | Some (_, _, Some message) -> View_base.tr model message | _ -> "") request model_source) in
  let loading = own (Signal.map2 (fun ((_, deferred), raw) error -> deferred && raw = None && error = "")
    (own (Signal.map2 (fun request raw -> request, raw) request catalog)) error) in
  loaded, loading, error

type filter_draft = {key : int; attr : string; op : string; value : Json.t}
type sort_draft = {key : int; attr : string; asc : bool}
let filter_value_title col value = match value with
  | `List values -> String.concat ", " (List.map (fun value ->
      match List.find_opt (fun choice -> jfield "match" choice = `List [value]) (jlist (jfield "filterValues" col)) with
      | Some choice -> jtext (jfield "title" choice) | None -> text_value value) values)
  | value -> input_value value

let temporal_default kind =
  let now = Unix.gettimeofday () in
  if kind = "datetime" then Printf.sprintf "%.0f" (floor (now /. 60.) *. 60000.)
  else let t = Unix.localtime now in Printf.sprintf "%04d-%02d-%02d" (t.Unix.tm_year + 1900) (t.tm_mon + 1) t.tm_mday

let temporal_picker ?on_submit model_source kind id source set : t = fun context parent ->
  let picker_value value =
    try
      if kind = "date" then Option.map (fun day ->
        Printf.sprintf "%04d-%02d-%02d" (day / 10000) (day / 100 mod 100) (day mod 100))
        (Natural_date.day value)
      else Option.bind (Natural_date.timestamp value) (fun ms ->
        let tm = Unix.localtime (float_of_int ms /. 1000.) in
        let year = tm.Unix.tm_year + 1900 in
        if year < 1 || year > 9999 then None
        else Some (string_of_int (int_of_float (fst (Unix.mktime {tm with tm_sec = 0}) *. 1000.))))
    with Failure _ | Invalid_argument _ | Unix.Unix_error _ -> None in
  let initial = Signal.sample source in
  let input = Signal.state context.Lui_ui.ui_scheduler "" in
  let selection = Signal.state context.ui_scheduler
    (Option.value ~default:(temporal_default kind) (picker_value initial)) in
  let sync value =
    let selected = picker_value value in
    Option.iter (Signal.set selection) selected;
    selected in
  let observed = ref initial in
  ignore (Signal.own context.ui_scope (Signal.observe source (fun value ->
    if value <> !observed then (
      observed := value;
      ignore (sync value)))));
  let update value =
    observed := value;
    set value in
  let calendar : t = fun context parent ->
  let node = Lui_ui.extension context "native-property-date" in
  attach context parent node;
  Lui_ui.extension_property context node "kind" (Lui_protocol.StringValue kind);
  Lui_ui.extension_property context node "identifier" (Lui_protocol.StringValue ("view.edit.date." ^ id));
  Lui_ui.extension_property_signal context node "value"
    (Signal.map (fun value -> Lui_protocol.StringValue value) (Signal.value selection));
  Lui_ui.on_event context node (function
    | Lui_protocol.ExtensionEvent (_, _, "change", fields) ->
      (match Lui_protocol.String_map.find_opt "value" fields with
       | Some (Lui_protocol.StringValue value) ->
         (match picker_value value with
          | Some selected when selected <> Signal.sample (Signal.value selection) ->
            Signal.set selection selected;
            Signal.set input "";
            update value
          | _ -> ())
       | _ -> ())
    | _ -> ());
  node in
  (column ~gap:8 [
      text_field ~text_signal:(Signal.value input)
        ~placeholder:"YYYY-MM-DD / tomorrow / next Friday"
        ~label:(View_base.tr (Signal.sample model_source) "Date picker")
        ~accessibility_identifier:("view.edit.date.input." ^ id)
        ~on_input:(function Lui_protocol.TextChanged (_, value) ->
          Signal.set input value;
          Option.iter update (sync value)
          | _ -> ())
        ?on_submit [];
      calendar]) context parent

let filter_transition op value =
  let number = function `Int _ | `Float _ -> true | _ -> false in
  let keep = match op with
    | "is" | "is-not" -> (match value with `List _ -> true | _ -> false)
    | "text-contains" | "text-not-contains" -> (match value with `String _ -> true | _ -> false)
    | "between" -> (match value with `List values -> List.for_all (fun value -> value = `Null || number value) values | _ -> false)
    | _ -> number value in
  if keep then value else `Null
let filter_error (draft : filter_draft) =
  let number = function `Null | `Int _ | `Float _ -> true | _ -> false in
  if draft.op = "between" then
    let values = jlist draft.value in
    if not (List.for_all number values) then Some "Enter a number or leave a bound empty."
    else (match values with
      | [lo; hi] when lo <> `Null && hi <> `Null ->
        let n = function `Int n -> float_of_int n | `Float n -> n | _ -> 0. in
        if n lo > n hi then Some "Minimum must not exceed maximum." else None
      | _ -> None)
  else if List.mem draft.op ["number-gt"; "number-lt"; "number-gte"; "number-lte"] && not (number draft.value)
  then Some "Enter a valid number." else None

let settings_sheet mode owner feature view_source model_source send close : t =
 fun context parent ->
  let initial = Signal.sample view_source in
  let own value = Signal.own_signal context.ui_scope value in
  let state value = Signal.state context.ui_scheduler value in
  let or_ = state (jbool (jfield "or?" (jfield "filters" initial.data))) in
  let filters = state (List.mapi (fun key -> function
    | `List [`String attr; `String op; value] -> {key; attr; op; value}
    | _ -> {key; attr = "block/title"; op = "text-contains"; value = `String ""})
      (jlist (jfield "filters" (jfield "filters" initial.data)))) in
  let sorts = state (List.mapi (fun key value -> {key; attr = jtext (jfield "id" value); asc = jbool (jfield "asc?" value)})
      (jlist (jfield "sorting" initial.data))) in
  let sequence = ref (List.length (Signal.sample (Signal.value filters)) + List.length (Signal.sample (Signal.value sorts))) in
  let next () = incr sequence; !sequence in
  let update_filter key change = Signal.set filters (List.map (fun (value : filter_draft) -> if value.key = key then change value else value)
      (Signal.sample (Signal.value filters))) in
  let update_sort key change = Signal.set sorts (List.map (fun (value : sort_draft) -> if value.key = key then change value else value)
      (Signal.sample (Signal.value sorts))) in
  let choose_property label value choose = menu ~text_signal:label ~label:(View_base.tr (Signal.sample model_source) "Property") [
    keyed ~source:(own (Signal.map property_choices view_source)) ~key:(fun col -> jtext (jfield "attr" col)) ~cmp:String.compare
      ~mount:(fun col -> let col = Signal.sample col in
        menu_item ~text:(property_title (Signal.sample model_source) col) ~selected_signal:(own (Signal.map ((=) (jtext (jfield "attr" col))) value))
          ~on_press:(fun _ -> choose (jtext (jfield "attr" col))) [])] in
  let filter_row source : t = fun context parent ->
    let own value = Signal.own_signal context.ui_scope value in
    let state value = Signal.state context.ui_scheduler value in
    let first : filter_draft = Signal.sample source in
    let id part = "view.filter." ^ part ^ "." ^ initial.id ^ "." ^ string_of_int first.key in
    let attr = own (Signal.map (fun (draft : filter_draft) -> draft.attr) source) in
    let col, loading, load_error = loaded_column context ~id:(initial.id ^ ".filter." ^ string_of_int first.key)
      ~owner ~mode:"filter" ~feature (own (Signal.map2 view_column view_source attr)) model_source send in
    let change f = update_filter first.key f in
    let set_value value = change (fun draft -> {draft with value}) in
    let selecting = state false in
    let selection = state `Null in
    let query = state "" in
    let custom = state false in
    let numeric text = match float_of_string_opt (String.trim text) with
      | Some n when Float.is_finite n -> `Float n
      | _ -> if String.trim text = "" then `Null else `String text in
    let number_input part label index = text_field ~grow:1.0 ~placeholder:label ~label
      ~accessibility_identifier:(id part)
      ~text_signal:(own (Signal.map (fun (draft : filter_draft) ->
        input_value (match index with None -> draft.value | Some index ->
          Option.value ~default:`Null (List.nth_opt (jlist draft.value) index))) source))
      ~on_input:(local_input (fun text -> change (fun draft -> {draft with value =
        match index with None -> numeric text | Some index ->
          `List (List.init 2 (fun i -> if i = index then numeric text else
            Option.value ~default:`Null (List.nth_opt (jlist draft.value) i)))}))) [] in
    let choose_values = button ~variant:`ghost ~text_alignment:`start ~min_height:44 ~grow:1.0
      ~text_signal:(own (Signal.map2 (fun col (draft : filter_draft) ->
        match draft.value with `Null | `List [] -> "Select values" | `String "empty" -> "Empty"
        | `Bool b -> if b then "Checked" else "Unchecked" | value -> filter_value_title col value) col source))
      ~accessibility_identifier:(id "values") ~on_press:(fun _ ->
        Signal.set selection (Signal.sample source).value; Signal.set query ""; Signal.set selecting true) [] in
    let values_sheet =
      let option key label matched = button ~variant:`ghost ~min_height:44 ~text_alignment:`start
        ~text:label ~accessibility_identifier:(id "choice" ^ "." ^ key)
        ~icon_signal:(own (Signal.map (fun selected -> `app (if selected = matched then "task-done" else "outliner-bullet")) (Signal.value selection)))
        ~on_press:(fun _ -> Signal.set selection matched) [] in
      let filtered = own (Signal.map2 (fun col query ->
        jlist (jfield "filterValues" col) |> List.filter (fun value ->
          String_kit.includes ~sub:(String.lowercase_ascii query) (String.lowercase_ascii (jtext (jfield "title" value))))) col (Signal.value query)) in
      let cancel = button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
        ~accessibility_identifier:(id "values.cancel") ~on_press:(fun _ -> Signal.set selecting false) [] in
      let done_ = button ~text:(View_base.tr (Signal.sample model_source) "Done") ~variant:`ghost ~style_class:"confirmation-action"
        ~accessibility_identifier:(id "values.done") ~on_press:(fun _ -> set_value (Signal.sample (Signal.value selection)); Signal.set selecting false) [] in
      sheet ~text_signal:(own (Signal.map2 property_title model_source col))
        ~style_class:"navigation-list navigation-inline-title" ~detents:"medium,large"
        ~accessibility_identifier:(id "values.sheet") ~on_dismiss:(fun _ -> Signal.set selecting false) [
        list ~grow:1.0 ~style:`inset_grouped [
          list_section [list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [text_field ~placeholder:(View_base.tr (Signal.sample model_source) "Search values") ~label:(View_base.tr (Signal.sample model_source) "Search values")
            ~accessibility_identifier:(id "values.search") ~text_signal:(Signal.value query)
            ~on_input:(local_input (Signal.set query)) []]];
          list_section [list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [option "empty" "Empty" (`String "empty")];
            list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [option "any" "Any value" `Null]];
          dyn (fun col -> if jfield "kind" col = `String "checkbox" then
            list_section [list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [option "true" "Checked" (`Bool true)]; list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [option "false" "Unchecked" (`Bool false)]]
            else list_section [
              keyed ~source:(own (Signal.map (List.mapi (fun i value -> i, value)) filtered))
                ~key:(fun (_, value) -> Json.to_string value) ~cmp:String.compare ~mount:(fun value ->
                  let index, value = Signal.sample value in
                  let matched = jlist (jfield "match" value) in
                  list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [button ~text:(jtext (jfield "title" value)) ~variant:`ghost ~min_height:44 ~text_alignment:`start
                    ~accessibility_identifier:(id "choice" ^ "." ^ string_of_int index)
                    ~icon_signal:(own (Signal.map (fun selected -> `app (if matched <> [] &&
                      List.for_all (fun value -> List.mem value (jlist selected)) matched then "task-done" else "outliner-bullet")) (Signal.value selection)))
                    ~on_press:(fun _ -> let current = jlist (Signal.sample (Signal.value selection)) in
                      Signal.set selection (`List (if List.for_all (fun value -> List.mem value current) matched then
                        List.filter (fun value -> not (List.mem value matched)) current
                        else current @ List.filter (fun value -> not (List.mem value current)) matched))) []])]) col];
        (if Lui_ui.host context = KotlinHost then row ~main:`space_between ~padding:12 [cancel; done_]
         else toolbar ~style_class:"navigation-actions" [cancel; done_])
      ] in
    let temporal kind =
      let value = own (Signal.map (fun (draft : filter_draft) ->
        if draft.value = `Null then temporal_default kind else input_value draft.value) source) in
      temporal_picker model_source kind (id "date") value (fun value ->
        if kind = "datetime" then (match Natural_date.timestamp value with Some value -> set_value (`Int value) | None -> ())
        else match Natural_date.day value with
          | Some day -> set_value (`Assoc ["block/journal-day", `Int day]) | None -> ()) in
    let timestamp = column ~gap:0 ~cross:`stretch [
      menu ~label:(View_base.tr (Signal.sample model_source) "Date range") ~accessibility_identifier:(id "timestamp")
        ~text_signal:(own (Signal.map (fun (draft : filter_draft) -> match draft.value with
          | `String label -> label | `Int _ | `Float _ -> "Custom date" | _ -> "Choose date") source))
        (List.map (fun (key, label) -> menu_item ~text:label ~accessibility_identifier:(id "preset" ^ "." ^ key)
          ~on_press:(fun _ -> Signal.set custom false; set_value (`String label)) [])
          ["day", "1 day ago"; "three-days", "3 days ago"; "week", "1 week ago";
           "month", "1 month ago"; "three-months", "3 months ago"; "year", "1 year ago"] @
         [menu_item ~text:(View_base.tr (Signal.sample model_source) "Custom date…") ~accessibility_identifier:(id "custom")
           ~on_press:(fun _ -> Signal.set custom true; let current = (Signal.sample source).value in
             match current with `Int _ | `Float _ -> () | _ ->
               set_value (`Int (int_of_string (temporal_default "datetime")))) []]);
      if_ ~test:(own (Signal.map2 (fun custom (draft : filter_draft) -> custom ||
        match draft.value with `Int _ | `Float _ -> true | _ -> false) (Signal.value custom) source)) (temporal "datetime")
    ] in
    (list_section [
      list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [row ~gap:4 ~cross:`center ~accessibility_identifier:(id "row") [
        box ~grow:1.0 [menu ~text_signal:(own (Signal.map2 property_title model_source col)) ~label:(View_base.tr (Signal.sample model_source) "Property") [
          keyed ~source:(own (Signal.map property_choices view_source)) ~key:(fun col -> jtext (jfield "attr" col)) ~cmp:String.compare
            ~mount:(fun col -> let col = Signal.sample col in let attr = jtext (jfield "attr" col) in
              menu_item ~text:(property_title (Signal.sample model_source) col) ~accessibility_identifier:(id "property" ^ "." ^ attr)
                ~on_press:(fun _ -> Signal.set custom false; change (fun draft ->
                  {draft with attr; op = (if jbool (jfield "filterTimestamp" col) then "after" else "is"); value = `Null})) [])]];
        menu ~text_signal:(own (Signal.map (fun (draft : filter_draft) -> operator_title draft.op) source)) ~label:(View_base.tr (Signal.sample model_source) "Operator") [
          keyed ~source:(own (Signal.map operators col)) ~key:Fun.id ~cmp:String.compare
            ~mount:(fun op -> let op = Signal.sample op in menu_item ~text:(operator_title op)
              ~accessibility_identifier:(id "operator" ^ "." ^ op)
              ~on_press:(fun _ -> Signal.set custom false; change (fun draft -> {draft with op; value = filter_transition op draft.value})) [])];
        button ~icon:(`app "close") ~variant:`ghost ~width:44 ~height:44 ~label:(View_base.tr (Signal.sample model_source) "Remove filter")
          ~accessibility_identifier:(id "remove") ~on_press:(fun _ -> Signal.set filters
            (List.filter (fun (draft : filter_draft) -> draft.key <> first.key) (Signal.sample (Signal.value filters)))) []]];
      if_ ~test:loading (list_item [spinner []]);

      list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [dyn (fun op -> match op with
        | "is" | "is-not" -> choose_values
        | "between" -> row ~gap:8 [number_input "minimum" "Minimum" (Some 0); number_input "maximum" "Maximum" (Some 1)]
        | "number-gt" | "number-lt" | "number-gte" | "number-lte" -> number_input "value" "Number" None
        | "date-before" | "date-after" -> temporal "date"
        | "before" | "after" -> timestamp
        | _ -> text_field ~label:(View_base.tr (Signal.sample model_source) "Filter value") ~placeholder:(View_base.tr (Signal.sample model_source) "Text") ~accessibility_identifier:(id "value")
            ~text_signal:(own (Signal.map (fun (draft : filter_draft) -> input_value draft.value) source))
            ~on_input:(local_input (fun value -> set_value (`String value))) [])
        (own (Signal.map (fun (draft : filter_draft) -> draft.op) source))];
      if_ ~test:(own (Signal.map (fun draft -> filter_error draft <> None) source))
        (list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [text ~foreground:"destructive" ~accessibility_identifier:(id "error")
          ~value_signal:(own (Signal.map (fun draft -> Option.value ~default:"" (filter_error draft)) source)) []]);
      if_ ~test:(Signal.value selecting) (list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [values_sheet]);
    ]) context parent in
  let sort_row source : t =
    let first : sort_draft = Signal.sample source in
    let attr_source = own (Signal.map (fun (value : sort_draft) -> value.attr) source) in
    list_section ~header:(text ~value_signal:(own (Signal.map (fun values ->
      let rec position index = function
        | [] -> index | (value : sort_draft) :: _ when value.key = first.key -> index
        | _ :: rest -> position (index + 1) rest in
      "Sort " ^ string_of_int (position 1 values)) (Signal.value sorts))) []) [
      list_item [row ~gap:8 ~main:`space_between ~cross:`center [
        choose_property (own (Signal.map2 (fun view attr -> property_title (Signal.sample model_source) (view_column view attr)) view_source attr_source)) attr_source
          (fun attr -> update_sort first.key (fun value -> {value with attr}));
        menu ~text_signal:(own (Signal.map (fun (value : sort_draft) -> if value.asc then "Ascending" else "Descending") source))
          ~label:(View_base.tr (Signal.sample model_source) "Sort direction") (List.map (fun asc -> menu_item ~text:(if asc then "Ascending" else "Descending")
            ~selected_signal:(own (Signal.map (fun (value : sort_draft) -> value.asc = asc) source))
            ~on_press:(fun _ -> update_sort first.key (fun value -> {value with asc})) []) [true; false]);
        menu ~icon:(`app "more-horiz") ~label:(View_base.tr (Signal.sample model_source) "Sort actions") [
          menu_item ~text:(View_base.tr (Signal.sample model_source) "Move up") ~on_press:(fun _ ->
            let rec move = function
              | previous :: (value : sort_draft) :: rest when value.key = first.key -> value :: previous :: rest
              | value :: rest -> value :: move rest | [] -> [] in
            Signal.set sorts (move (Signal.sample (Signal.value sorts)))) [];
          menu_item ~text:(View_base.tr (Signal.sample model_source) "Remove") ~variant:`destructive ~on_press:(fun _ ->
            Signal.set sorts (List.filter (fun (value : sort_draft) -> value.key <> first.key) (Signal.sample (Signal.value sorts)))) [];
        ];
      ]];
    ] in
  let save _ =
    let filters = Signal.sample (Signal.value filters) and sorts = Signal.sample (Signal.value sorts) in
    let config = `Assoc (if mode = "filter" then [
      "filters", `Assoc ["or", `Bool (Signal.sample (Signal.value or_)); "clauses", `List (List.map (fun (value : filter_draft) ->
        `List [`String value.attr; `String value.op; value.value]) filters)]]
      else ["sorting", `List (List.map (fun (value : sort_draft) -> `Assoc ["id", `String value.attr; "asc", `Bool value.asc]) sorts)]) in
    ignore (send (Model.SubmitResultView (initial.id, payload owner feature initial.id "save" ["config", config]))) in
  let cancel = button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
    ~accessibility_identifier:("view.settings.cancel." ^ initial.id) ~on_press:(fun _ -> close ()) [] in
  let save = button ~text:(View_base.tr (Signal.sample model_source) "Done") ~variant:`ghost ~style_class:"confirmation-action"
    ~disabled_signal:(own (Signal.map2 (fun waiting filters -> waiting || (mode = "filter" && List.exists (fun draft -> filter_error draft <> None) filters))
      (waiting model_source initial.id) (Signal.value filters)))
    ~accessibility_identifier:("view.settings.save." ^ initial.id) ~on_press:save [] in
  (sheet ~text:(if mode = "filter" then "Filters" else "Sort") ~style_class:"navigation-list navigation-inline-title" ~detents:"medium,large"
    ~accessibility_identifier:("view.settings.sheet." ^ initial.id)
    ~on_dismiss:(fun _ -> close ()) [
      list ~grow:1.0 ~style:`inset_grouped ~accessibility_identifier:("view." ^ mode ^ ".list." ^ initial.id)
        (
        (if mode = "filter" then [
          list_section [list_item ~padding_vertical:0 ~padding_horizontal:16 ~min_height:44 [menu ~label:(View_base.tr (Signal.sample model_source) "Match conditions")
            ~text_signal:(own (Signal.map (fun any -> if any then "Match any condition" else "Match all conditions") (Signal.value or_)))
            (List.map (fun any -> menu_item ~text:(if any then "Any condition" else "All conditions")
              ~accessibility_identifier:("view.filter.match." ^ initial.id ^ "." ^ string_of_bool any)
              ~selected_signal:(own (Signal.map ((=) any) (Signal.value or_))) ~on_press:(fun _ -> Signal.set or_ any) []) [false; true])]];
          if_ ~test:(own (Signal.map ((=) []) (Signal.value filters)))
            (list_section [list_item [button ~text:(View_base.tr (Signal.sample model_source) "Created in the last month") ~icon:(`app "calendar") ~variant:`ghost
              ~accessibility_identifier:("view.filter.recent." ^ initial.id) ~on_press:(fun _ ->
                Signal.set filters [{key = next (); attr = "block/created-at"; op = "after"; value = `String "1 month ago"}]) []]]);
          keyed ~source:(Signal.value filters) ~key:(fun (value : filter_draft) -> value.key) ~cmp:Int.compare ~mount:filter_row;
          list_section [list_item [button ~text:(View_base.tr (Signal.sample model_source) "Add filter") ~variant:`ghost ~accessibility_identifier:("view.filter.add." ^ initial.id)
            ~on_press:(fun _ -> Signal.set filters (Signal.sample (Signal.value filters) @ [{key = next (); attr = "block/title"; op = "text-contains"; value = `String ""}])) []]];
        ] else [
          keyed ~source:(Signal.value sorts) ~key:(fun (value : sort_draft) -> value.key) ~cmp:Int.compare ~mount:sort_row;
          list_section [list_item [button ~text:(View_base.tr (Signal.sample model_source) "Add sort") ~variant:`ghost ~accessibility_identifier:("view.sort.add." ^ initial.id)
            ~on_press:(fun _ -> Signal.set sorts (Signal.sample (Signal.value sorts) @ [{key = next (); attr = "block/title"; asc = true}])) []]];
        ]));
      (if Lui_ui.host context = KotlinHost then row ~main:`space_between ~padding:12 [cancel; save]
       else toolbar ~label:(View_base.tr (Signal.sample model_source) "View settings actions") ~style_class:"navigation-actions" [cancel; save]);
    ]) context parent

let rec raw_selection_values raw =
  match jtext (jfield "type" raw) with
  | "ref-uuid" -> [jtext (jfield "value" raw)]
  | "set" | "vector" -> List.concat_map raw_selection_values (jlist (jfield "value" raw))
  | "" -> []
  | _ -> [text_value (jfield "value" raw)]

let property_editor ?(owner = "") ?(send = fun _ -> false) ?open_node ?(open_nodes = []) ~id ~column:col ~submit:save model_source property close : t =
 fun context parent ->
  let view = {id; name = ""; typ = ""; data = `Null} in
  let own value = Signal.own_signal context.ui_scope value in
  let state value = Signal.state context.ui_scheduler value in
  let attr = jtext (jfield "attr" property) in
  let plain = attr = "block/title" || jbool (jfield "textLayout" property) in
  let checkbox = jfield "kind" col = `String "checkbox" in
  let kind = jtext (jfield "kind" col) in
  let many = jbool (jfield "many" col) in
  let ref_ = jbool (jfield "ref" col) in
  let closed = jlist (jfield "choices" col) <> [] || jbool (jfield "closed" col) in
  let temporal = not closed && List.mem kind ["date"; "datetime"] in
  let query = state (if temporal then (match jtext (jfield "editorValue" property) with "" -> temporal_default kind | value -> value)
    else if attr = "block/title" && jtext (jfield "editorValue" property) <> "" then jtext (jfield "editorValue" property)
    else if attr = "block/title" then (match jfield "raw" property with
      | `Assoc fields when List.assoc_opt "type" fields = Some (`String "string") ->
        jtext (Option.value ~default:`Null (List.assoc_opt "value" fields))
      | _ -> jtext (jfield "text" property))
    else if plain then jtext (jfield "text" property) else "") in
  let selected = state (raw_selection_values (jfield "raw" property)) in
  let created = state [] in
  let submit ?selected_values ?(new_values = []) ?(create = false) value =
    save
      (["attr", `String attr;
        "expected", jfield "raw" property; "value", `String value; "create", `Bool create]
       @ (match selected_values with None -> [] | Some values -> ["selectedValues", `List (List.map (fun value -> `String value) values)])
       @ (if new_values = [] then [] else ["newValues", `List (List.map (fun value -> `String value) new_values)])) in
  let column = if plain || checkbox || temporal || closed then
    `Assoc (("valuesDeferred", `Bool false) :: List.remove_assoc "valuesDeferred" (fields col)) else col in
  let column, loading, load_error = loaded_column context ~id:view.id ~owner ~mode:"property" ~feature:""
    (Signal.constant context.ui_scheduler column) model_source send in
  let options = own (Signal.map (fun col ->
    let choices = jlist (jfield "choices" col) in
    if closed then List.map (fun choice ->
      jtext (jfield "uuid" choice), jtext (jfield "title" choice)) choices
    else List.map (fun choice ->
      let value = if ref_ then match jlist (jfield "match" choice) with
        | [`String uuid] -> uuid | _ -> ""
        else text_value (jfield "value" choice) in
      value, jtext (jfield "title" choice)) (jlist (jfield "filterValues" col))
    |> List.filter (fun (value, _) -> value <> "")) column) in
  let visible = own (Signal.map2 (fun options input -> List.filter (fun (_, title) ->
    String_kit.includes ~sub:(Dev_query.Unicode.lowercase input) (Dev_query.Unicode.lowercase title)) options) options (Signal.value query)) in
  let visible_limit = state 50 in
  ignore (Signal.own context.ui_scope (Signal.observe (Signal.value query) (fun _ -> Signal.set visible_limit 50)));
  let mounted_options = own (Signal.map2 (fun options limit -> List.filteri (fun index _ -> index < limit) options)
    visible (Signal.value visible_limit)) in
  let toggle value =
    let values = Signal.sample (Signal.value selected) in
    Signal.set selected (if List.mem value values then List.filter ((<>) value) values else values @ [value]) in
  let choose value =
    if many then toggle value
    else if ref_ then submit ~selected_values:[value] "" else submit value in
  let can_create = not closed && not plain && not checkbox && not temporal &&
    (jfield "canCreate" col <> `Bool false) in
  let create_visible = own (Signal.map2 (fun (options, loading) input -> not loading && can_create && String.trim input <> ""
    && not (List.exists (fun (_, title) -> Dev_query.Unicode.lowercase title = Dev_query.Unicode.lowercase (String.trim input)) options)
    && not (List.mem (String.trim input) (Signal.sample (Signal.value created)))) (own (Signal.map2 (fun options loading -> options, loading) options loading)) (Signal.value query)) in
  let confirm_input _ = if plain || temporal then submit (Signal.sample (Signal.value query))
    else if ref_ then submit ~selected_values:(Signal.sample (Signal.value selected))
      ~new_values:(Signal.sample (Signal.value created)) ~create:true ""
    else submit (String.concat ", " (Signal.sample (Signal.value selected) @ Signal.sample (Signal.value created))) in
  let cancel = button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
    ~accessibility_identifier:("view.edit.cancel." ^ view.id) ~on_press:(fun _ -> close ()) [] in
  let confirm = button ~text:(View_base.tr (Signal.sample model_source) "Done") ~variant:`ghost ~style_class:"confirmation-action"
    ~accessibility_identifier:("view.edit.save." ^ view.id)
    ~disabled_signal:(waiting model_source view.id) ~on_press:confirm_input [] in
  let option_row (value, title) = list_item ~height:44 ~padding_vertical:0 [
    menu_item ~text:title ~height:44 ~padding_vertical:0
      ~selected_signal:(own (Signal.map (List.mem value) (Signal.value selected)))
      ~disabled_signal:(waiting model_source view.id)
      ~accessibility_identifier:("view.edit.option." ^ view.id ^ "." ^ value)
      ~on_press:(fun _ -> choose value) []] in
  let controls = if plain || temporal || many then [cancel; confirm] else [cancel] in
  (sheet ~text:(property_title (Signal.sample model_source) col)
    ~style_class:"navigation-list navigation-inline-title" ~detents:"medium,large"
    ~accessibility_identifier:("view.edit.sheet." ^ view.id) ~on_dismiss:(fun _ -> close ()) [
    list ~grow:1.0 ~style:`inset_grouped ~track_visible_range:true
      ~accessibility_identifier:("view.edit.list." ^ view.id)
      ~on_visible_range:(function Lui_protocol.VisibleRange (_, _, last) ->
        let limit = Signal.sample (Signal.value visible_limit) in
        let total = List.length (Signal.sample visible) in
        if last >= limit - 6 && limit < total then Signal.set visible_limit (min total (limit + 50))
        | _ -> ())
      ((match open_node with None -> [] | Some (label, open_) -> [list_section [list_item [
          menu_item ~text:label ~min_height:44 ~accessibility_identifier:("view.edit.open." ^ id)
            ~on_press:(fun _ -> close (); open_ ()) []]]]) @
       (if open_nodes = [] then [] else [list_section (List.map (fun (uuid, label, open_) ->
          list_item [menu_item ~text:label ~min_height:44 ~accessibility_identifier:("view.edit.open." ^ id ^ "." ^ uuid)
            ~on_press:(fun _ -> close (); open_ ()) []]) open_nodes)]) @
       (if temporal then [list_section [list_item ~padding_horizontal:0 ~padding_vertical:0 [
        temporal_picker ~on_submit:confirm_input model_source kind view.id (Signal.value query) (Signal.set query)]]]
        else if plain then [list_section [list_item [
        (if jbool (jfield "textLayout" property) then textarea ~min_height:120 ~max_height:260 ~submit_on_enter:false
          ~text_signal:(Signal.value query) ~label:(View_base.tr (Signal.sample model_source) "Set value") ~placeholder:(View_base.tr (Signal.sample model_source) "Set value") ~autofocus:true
          ~accessibility_identifier:("view.edit.value." ^ view.id) ~on_input:(local_input (Signal.set query)) []
        else text_field ~text_signal:(Signal.value query)
          ~label:(View_base.tr (Signal.sample model_source) "Set value") ~placeholder:(View_base.tr (Signal.sample model_source) "Set value") ~autofocus:true ~accessibility_identifier:("view.edit.value." ^ view.id)
          ~on_input:(local_input (Signal.set query)) [])]]]
        else if checkbox then [list_section (List.map (fun value -> list_item [
          menu_item ~text:(View_base.tr (Signal.sample model_source) (if value then "True" else "False")) ~min_height:44
            ~selected:(jfield "value" (jfield "raw" property) = `Bool value)
            ~accessibility_identifier:("view.edit.bool." ^ string_of_bool value ^ "." ^ view.id)
            ~disabled_signal:(waiting model_source view.id) ~on_press:(fun _ -> submit (string_of_bool value)) []]) [true; false])]
        else [
          search_field ~container_relative_frame:`horizontal ~padding_horizontal:16
            ~text_signal:(Signal.value query) ~placeholder:(View_base.tr (Signal.sample model_source) "Select a choice") ~label:(View_base.tr (Signal.sample model_source) "Search")
            ~accessibility_identifier:("view.edit.value." ^ view.id) ~on_input:(local_input (Signal.set query)) [];
          list_section [
            if_ ~test:loading (list_item [spinner ~accessibility_identifier:("view.edit.loading." ^ id) []]);

            keyed ~source:mounted_options ~key:fst ~cmp:String.compare ~mount:(fun source -> option_row (Signal.sample source));
            keyed ~source:(Signal.value created) ~key:Fun.id ~cmp:String.compare ~mount:(fun source ->
              let value = Signal.sample source in list_item ~height:44 ~padding_vertical:0 [menu_item ~height:44 ~padding_vertical:0 ~text:value ~selected:true
                ~on_press:(fun _ -> Signal.set created (List.filter ((<>) value) (Signal.sample (Signal.value created)))) []]);
            if_ ~test:create_visible (list_item [button ~variant:`ghost ~text_alignment:`start ~min_height:44
              ~text_signal:(own (Signal.map (fun input -> View_base.tr_named (Signal.sample model_source)
                "Create {1}" (String.trim input)) (Signal.value query)))
              ~accessibility_identifier:("view.edit.create." ^ view.id) ~disabled_signal:(waiting model_source view.id)
              ~on_press:(fun _ -> let value = String.trim (Signal.sample (Signal.value query)) in
                if many then (Signal.set created (Signal.sample (Signal.value created) @ [value]); Signal.set query "")
                else submit ~create:true value) []]);
          ];
        ]) @ [
        if_ ~test:(Signal.constant context.ui_scheduler (attr <> "block/title"))
        (list_section [list_item [button ~text:(View_base.tr (Signal.sample model_source) "Clear") ~variant:`ghost ~min_height:44
          ~accessibility_identifier:("view.edit.clear." ^ view.id) ~disabled_signal:(waiting model_source view.id)
          ~on_press:(fun _ -> if plain then submit "" else if many then (Signal.set selected []; Signal.set created []) else submit "") []]]);

      ]);
    (if Lui_ui.host context = KotlinHost then row ~main:`space_between ~padding:12 controls
     else toolbar ~label:(View_base.tr (Signal.sample model_source) "Actions") ~style_class:"navigation-actions" controls);
  ]) context parent

let value_sheet owner feature view model_source send item property close =
  let column = view_column view (jtext (jfield "attr" property)) in
  let column = match column, property with
    | `Assoc fields, `Assoc editor ->
      let overrides = List.filter (fun (key, _) -> List.mem key ["choices"; "closed"; "canCreate"]) editor in
      `Assoc (overrides @ List.filter (fun (key, _) -> not (List.mem_assoc key overrides)) fields)
    | _ -> column in
  let open_node = if jfield "attr" property <> `String "block/title" then None else Option.map (fun uuid ->
    (if Option.fold ~none:false ~some:(fun block -> block.row.Model.opens_as_page) item.block then "Open page" else "Open node"),
    (fun () -> ignore (send (View_base.request_node_action (Signal.sample model_source) uuid)))) item.uuid in
  let open_nodes = List.map (fun reference -> let uuid = jtext (jfield "uuid" reference) in
    uuid, View_base.tr_named (Signal.sample model_source) "Open {1}" (jtext (jfield "title" reference)),
    (fun () -> ignore (send (View_base.request_node_action (Signal.sample model_source) uuid))))
    (jlist (jfield "references" property)) in
  property_editor ~owner:(Option.value ~default:"" item.uuid) ~send ?open_node ~open_nodes ~id:view.id ~column
    ~submit:(fun fields -> ignore (send (Model.SubmitResultView (view.id,
      payload owner feature view.id "editCell" (("blockUuid", `String (Option.value ~default:"" item.uuid)) :: fields)))))
    model_source property close

let table_column_width column = if jfield "attr" column = `String "block/title" then 260 else 170

let table_column_window columns (offset, width) =
  let total = List.fold_left (fun sum col -> sum + table_column_width col + 1) (-1) columns |> max 0 in
  let offset = min (max 0 offset) (max 0 (total - width)) in
  let rec collect position before visible after = function
    | [] -> before, List.rev visible, after
    | col :: rest ->
      let extent = table_column_width col in
      let stop = position + extent in
      if stop > offset && position < offset + width then
        collect (stop + 1) (if visible = [] then position else before) (col :: visible) (total - stop) rest
      else collect (stop + 1) before visible after rest in
  collect 0 0 [] total columns

let table_viewport ~fill_height identifier viewport children : t =
  let mount context parent =
    let node = Lui_ui.extension context "native-table-viewport" in
    attach context parent node;
    Lui_ui.extension_property context node "identifier" (Lui_protocol.StringValue identifier);
    Lui_ui.on_event context node (function
      | Lui_protocol.ExtensionEvent (_, _, "viewport-changed", fields) ->
        (match Lui_protocol.String_map.find_opt "offset" fields, Lui_protocol.String_map.find_opt "width" fields with
         | Some (Lui_protocol.IntValue offset), Some (Lui_protocol.IntValue width) when width > 0 ->
           Signal.set viewport (max 0 offset, width)
         | _ -> ())
      | _ -> ());
    List.iter (fun child -> ignore (child context (Some node))) children;
    node in
  if fill_height then box ~grow:1.0 [mount] else mount

let loaded_rows context ~owner ~feature view_source input model_source send =
  let own signal = Signal.own_signal context.Lui_ui.ui_scope signal in
  let initial = Signal.sample view_source in
  let initial_model = Signal.sample model_source in
  let prefix = Option.value ~default:"local" initial_model.Model.selected_graph_id ^ ":rows:" ^ owner ^ ":" ^ initial.id
    ^ ":" ^ string_of_int initial_model.next_effect_id ^ ":" in
  let range = Signal.state context.ui_scheduler (0, 12) in
  let retry_count = Signal.state context.ui_scheduler 0 in
  let page = Signal.state context.ui_scheduler initial in
  let loading = Signal.state context.ui_scheduler false and error = Signal.state context.ui_scheduler "" in
  let previous = ref initial and generation = ref 0 and requested = ref None in
  let previous_input = ref (Signal.sample input) in
  let has_range data input offset limit =
    let start = jint (jfield "rowOffset" data) and count = row_count data in
    jtext (jfield "input" data) = input && start <= offset &&
    start + List.length (jlist (jfield "rows" data)) >= min count (offset + limit) in
  let drive ((view, input), ((offset, limit), (model, _))) =
    if jfield "rowsDeferred" view.data <> `Bool true then Signal.set page view else (
      let reset = input <> !previous_input || jfield "sorting" view.data <> jfield "sorting" (!previous).data
        || jfield "filters" view.data <> jfield "filters" (!previous).data || view.typ <> (!previous).typ in
      if reset then Signal.set range (0, 12);
      previous_input := input;
      if not (Json.equal view.data (!previous).data) then (
        previous := view; incr generation; requested := None; Signal.set page view);
      let offset = if reset then 0 else offset in
      let key = prefix ^ string_of_int !generation ^ ":" ^ Json.to_string (`List [`String input; `Int offset; `Int limit]) in
      let current = Signal.sample (Signal.value page) in
      let candidate = match List.assoc_opt key model.Model.result_row_windows with
        | Some raw -> (try Some (Json.from_string raw) with _ -> None)
        | None when jfield "revision" current.data = jfield "revision" view.data
          && has_range current.data input offset limit -> Some current.data
        | None when has_range view.data input offset limit -> Some view.data
        | _ -> None in
      let failure = match List.find_opt (fun (id, _, _) -> id = key) model.result_view_feedback with
        | Some (_, _, Some message) -> View_base.tr model message | _ -> "" in
      Signal.set error failure;
      Signal.set loading (candidate = None && failure = "" && jlist (jfield "rows" current.data) = []);
      match candidate with
      | Some data -> if not (Json.equal data current.data) then Signal.set page {view with data}
      | None ->
        let busy = List.exists (function Model.LoadResultRowsEffect (_, key, _) -> String.starts_with ~prefix key | _ -> false)
          (model.pending_effects @ model.in_flight_effects) in
        if not busy && !requested <> Some key then (
          requested := Some key;
          ignore (send (Model.LoadResultRows (key, Json.to_string (`Assoc ([
            "key", `String key; "ownerUuid", `String owner; "featureType", `String feature; "viewUuid", `String view.id;
            "input", `String input; "offset", `Int offset; "limit", `Int limit] @
            Option.fold ~none:[] ~some:(fun id -> ["graphId", `String id]) model.selected_graph_id))))))) in
  let request = own (Signal.map2 (fun view_input range_model -> view_input, range_model)
    (own (Signal.map2 (fun view input -> view, input) view_source input))
    (own (Signal.map2 (fun range model -> range, model) (Signal.value range)
      (own (Signal.map2 (fun model retry -> model, retry) model_source (Signal.value retry_count)))))) in
  ignore (Signal.own context.ui_scope (Signal.observe request drive));
  drive (Signal.sample request);
  let visible columns first last =
    if first >= 0 && last >= first then (
      let current = (Signal.sample (Signal.value page)).data in
      let start = jint (jfield "rowOffset" current) and length = List.length (jlist (jfield "rows" current)) in
      if first < start + 2 && start > 0 || last >= start + length - 2 && start + length < row_count current then (
        let limit = min 64 (max 12 (((last - first + columns) / columns) * columns)) in
        let offset = min (max 0 (row_count current - 1)) (max 0 (first - max 0 ((limit - (last - first + 1)) / 2))) in
        Signal.set range (offset / columns * columns, limit))) in
  let retry () = requested := None; Signal.set retry_count (1 + Signal.sample (Signal.value retry_count)) in
  own (Signal.cutoff (=) (Signal.value page)), visible, Signal.value loading, Signal.value error, retry

let collection_json ?(fill_height = false) ~render_block model_source parsed send : t =
 fun context parent ->
  let own value = Signal.own_signal context.ui_scope value in
  let initial = Signal.sample parsed in
  let grow = if fill_height then 1.0 else 0.0 in
  let owner = jtext (jfield "ownerUuid" initial) and feature = jtext (jfield "featureType" initial) in
  let views = own (Signal.map saved_views_json parsed) in
  let active = Signal.state context.ui_scheduler "" and search = Signal.state context.ui_scheduler "" in
  let is_query_expansion json = member "expanded" json <> None in
  let source_expanded json = match member "expanded" json with Some (`Bool value) -> value | _ -> true in
  let expanded = Signal.state context.ui_scheduler (source_expanded initial) in
  ignore (Signal.own context.ui_scope (Signal.observe parsed (fun json ->
    if is_query_expansion json then Signal.set expanded (source_expanded json))));
  let search_open = Signal.state context.ui_scheduler false in
  let chosen = own (Signal.map2 (fun views id ->
    match List.find_opt (fun view -> view.id = id) views with Some view -> [view]
    | None -> list_take 1 views) views (Signal.value active)) in
  let results_toggle () =
    let label = own (Signal.map2 (fun views expanded ->
      if not expanded then "Results" else
      string_of_int (List.fold_left (fun count view -> max count (row_count view.data)) 0 views) ^ " results")
      views (Signal.value expanded)) in
    View_base.with_label_signal label
      (button ~variant:`ghost ~text_alignment:`start ~grow:1.0
        ~accessibility_identifier:("query.toggle." ^ owner)
        ~disabled_signal:(waiting model_source owner)
        ~on_press:(fun _ ->
          let next = not (Signal.sample (Signal.value expanded)) in
          if is_query_expansion (Signal.sample parsed) then
            ignore (send (Model.SubmitResultView (owner, payload owner feature "" "setExpanded" ["expanded", `Bool next])))
          else Signal.set expanded next)
        [results_disclosure context ("query.disclosure." ^ owner) (Signal.value expanded) label]) in
  let mount view_source : t =
   fun context parent ->
    let own value = Signal.own_signal context.ui_scope value in
    let view_source, visible_rows, rows_loading, rows_error, retry_rows =
      loaded_rows context ~owner ~feature view_source (Signal.value search) model_source send in
    let view = Signal.sample view_source in
    let limit = Signal.state context.ui_scheduler 20 in
    let settings = Signal.state context.ui_scheduler "" in
    let editing = Signal.state context.ui_scheduler None in
    let horizontal_viewport = Signal.state context.ui_scheduler
      (0, max 1 ((let width = (Signal.sample model_source).Model.viewport_width in if width > 0 then width else 390) - 32)) in
    let column_window = own (Signal.cutoff (=) (own (Signal.map2
      (fun view viewport -> table_column_window (choices view) viewport) view_source (Signal.value horizontal_viewport)))) in
    let rows = own (Signal.map2 (fun view input -> items view.data |> List.filter (fun item ->
      jfield "rowsDeferred" view.data = `Bool true || String.trim input = "" || String_kit.includes ~sub:(Dev_query.Unicode.lowercase input)
        (Dev_query.Unicode.lowercase item.title))) view_source (Signal.value search)) in
    let entries = own (Signal.map2 list_take (Signal.value limit) rows) in
    let finished = ref None in
    ignore (Signal.own context.ui_scope (Signal.observe (feedback model_source view.id) (function
      | Some (_, id, None) when !finished <> Some id -> finished := Some id; Signal.set editing None; Signal.set settings ""
      | _ -> ())));
    let edit row property =
      Signal.set editing (Some (row, property)) in
    let cell view item attr =
      let row = item.json in
      List.find_opt (fun property -> jfield "attr" property = `String attr) (jlist (jfield "properties" row))
        |> Option.value ~default:(`Assoc ["text", `String ""; "attr", `String attr; "raw", `Null;
          "editable", jfield "editable" (view_column view attr)]) in
    let table_cells view_id row_id cells =
      let rec separated = function
        | [] -> []
        | [(_, cell)] -> [cell]
        | (_, cell) :: ((next_attr, _) :: _ as rest) ->
          cell :: separator ~orientation:`vertical
            ~accessibility_identifier:("view.cell.separator." ^ view_id ^ "." ^ row_id ^ "." ^ next_attr) [] :: separated rest
      in separated cells in
    let windowed_cells (before, _, after) cells =
      (if before = 0 then [] else [box ~width:before []]) @ cells @
      (if after = 0 then [] else [box ~width:after []]) in
    let table_row item_source : t =
     fun row_context parent ->
      (dyn (fun ((view, item), ((_, visible_columns, _) as window)) -> row ~gap:0 ~cross:`stretch (windowed_cells window (table_cells view.id
        (Option.value ~default:(string_of_int item.index) item.uuid)
        (List.map (fun col -> let attr = jtext (jfield "attr" col) in attr,
        if String.starts_with ~prefix:"query.result/" attr then
          let index = int_of_string (String.sub attr 13 (String.length attr - 13)) in
          let values = jlist (jfield "cells" item.json) in
          text ~value:(Option.fold ~none:"" ~some:text_value (List.nth_opt values index)) ~style_class:"single-line" ~width:170 ~min_height:48 ~padding:12
            ~accessibility_identifier:("view.scalar." ^ view.id ^ "." ^ string_of_int item.index ^ "." ^ string_of_int index) []
        else
        let property = cell view item attr in
        let value = jtext (jfield "text" property) in
        let label = property_title (Signal.sample model_source) col ^ ": " ^
          (if value = "" then View_base.tr (Signal.sample model_source) "Empty" else value) in
        let identifier = "view.cell." ^ view.id ^ "." ^ Option.value ~default:"" item.uuid ^ "." ^ attr in
        let width = if attr = "block/title" then 260 else 170 in
        if jbool (jfield "editable" property) then
          button ~text:value ~label ~text_alignment:`start ~variant:`ghost ~style_class:"single-line"
            ~width ~min_height:48 ~corner_radius:0 ~padding_horizontal:12
            ~accessibility_identifier:identifier ~on_press:(fun _ -> edit item property) []
        else if attr = "block/title" && item.uuid <> None then
          button ~text:value ~label ~text_alignment:`start ~variant:`ghost ~style_class:"single-line"
            ~width ~min_height:48 ~corner_radius:0 ~padding_horizontal:12
            ~accessibility_identifier:identifier ~on_press:(fun _ -> Option.iter (fun uuid ->
              ignore (send (View_base.request_node_action (Signal.sample model_source) uuid))) item.uuid) []
        else text ~value ~text_alignment:`start ~style_class:"single-line" ~width ~min_height:48 ~padding:12
          ~accessibility_identifier:identifier []) visible_columns))))
        (Signal.own_signal row_context.Lui_ui.ui_scope (Signal.map2 (fun values window -> values, window)
          (Signal.map2 (fun view item -> view, item) view_source item_source) column_window))) row_context parent in
    let gallery_card item_source : t =
     fun card_context parent ->
      (dyn (fun (view, item) -> column ~gap:10 ~padding:16 ~background:"secondary" ~border_color:"border" ~border_width:1 ~corner_radius:12
        ~accessibility_identifier:("view.card." ^ view.id ^ "." ^ Option.value ~default:"" item.uuid) [
        button ~text:item.title ~text_alignment:`start ~variant:`ghost ~min_height:44
          ~on_press:(fun _ -> Option.iter (fun uuid -> ignore (send (View_base.request_node_action (Signal.sample model_source) uuid))) item.uuid) [];
        column ~gap:8 (choices view |> List.filter (fun col -> jfield "attr" col <> `String "block/title")
          |> List.map (fun col -> let property = cell view item (jtext (jfield "attr" col)) in
            row ~gap:12 ~main:`space_between [text ~value:(property_title (Signal.sample model_source) col) ~foreground:"muted-foreground" ~style_class:"caption" [];
              text ~value:(jtext (jfield "text" property)) ~style_class:"caption" []]))])
        (Signal.own_signal card_context.Lui_ui.ui_scope (Signal.map2 (fun view item -> view, item) view_source item_source))) card_context parent in
    let item_key item = match item.uuid with
      | Some uuid -> "block:" ^ uuid | None -> "tuple:" ^ string_of_int item.index in
    let result_window ?width ?(gap = 0) ?(columns = 1) ~identifier ~extent ~source ~key ~mount () : t =
     fun window_context parent ->
      let own signal = Signal.own_signal window_context.Lui_ui.ui_scope signal in
      let searches = own (Signal.map (fun input -> [input]) (Signal.value search)) in
      (if jfield "rowsDeferred" view.data = `Bool true then
        keyed ~source:searches ~key:Fun.id ~cmp:String.compare ~mount:(fun _ ->
          virtual_list ?width ?height:(if fill_height then None else Some 480) ~grow ~gap ~accessibility_identifier:identifier [
            View_rows.paged_keyed ~identifier:("view.window." ^ view.id) ~item_extent:extent
              ~count:(own (Signal.map (fun view -> (row_count view.data + columns - 1) / columns) view_source))
              ~offset:(own (Signal.map (fun view -> jint (jfield "rowOffset" view.data) / columns) view_source))
              ~on_visible_range:(fun first last -> visible_rows columns (first * columns) ((last + 1) * columns - 1))
              ~source ~key ~cmp:String.compare ~mount])
      else dyn (fun large ->
        if large || fill_height then
          (* Search owns a fresh viewport; ordinary value refreshes retain it. *)
          keyed ~source:searches
            ~key:Fun.id ~cmp:String.compare ~mount:(fun _ ->
              virtual_list ?width ?height:(if fill_height then None else Some 480) ~grow ~gap ~accessibility_identifier:identifier [
                View_rows.windowed_keyed ~window_size:12 ~identifier:("view.window." ^ view.id)
                  ~item_extent:extent ~source ~key ~cmp:String.compare ~mount])
        else column ?width ~gap ~accessibility_identifier:identifier [
          keyed ~source ~key ~cmp:String.compare ~mount])
        (own (Signal.map (fun rows -> List.length rows > 20) source))) window_context parent in
    let gallery_columns = own (Signal.map (fun (model : Model.logseq_model) ->
      if model.viewport_width >= 700 then 2 else 1) model_source) in
    let gallery_rows = own (Signal.map2 (fun columns items ->
      let rec collect current size groups = function
        | [] -> List.rev (if current = [] then groups else List.rev current :: groups)
        | item :: rest ->
          if size + 1 = columns then collect [] 0 (List.rev (item :: current) :: groups) rest
          else collect (item :: current) (size + 1) groups rest in
      collect [] 0 [] items) gallery_columns rows) in
    let error = own (Signal.map (fun view -> jtext (jfield "error" view.data)) view_source) in
    let layout = own (Signal.cutoff (fun (typ, columns, sorting, filters) (next_typ, next_columns, next_sorting, next_filters) ->
      typ = next_typ && Json.equal (`List columns) (`List next_columns)
      && Json.equal sorting next_sorting && Json.equal filters next_filters)
      (own (Signal.map (fun view -> view.typ, choices view,
        jfield "sorting" view.data, jfield "filters" view.data) view_source))) in
    (column ~grow ~gap:8 ~cross:`stretch [
      row ~gap:0 ~cross:`center ~accessibility_identifier:("view.toolbar." ^ owner) [
        (if feature = "query-result" then results_toggle () else
          row ~grow:1.0 ~cross:`center [
            View_base.with_string_prop TextAlignment "start"
              (menu ~text_signal:(own (Signal.map (fun view -> view.name) view_source))
              ~label:(View_base.tr (Signal.sample model_source) "Views") ~accessibility_identifier:("view.select." ^ owner) [
              keyed ~source:views ~key:(fun view -> view.id) ~cmp:String.compare ~mount:(fun source ->
                let saved = Signal.sample source in
                menu_item ~text_signal:(own (Signal.map (fun view -> view.name) source))
                  ~selected:(saved.id = view.id) ~accessibility_identifier:("view.tab." ^ saved.id)
                  ~on_press:(fun _ -> Signal.set active saved.id) [])]);
            box ~grow:1.0 []]);
        button ~icon:(`app "view-filter") ~label:(View_base.tr (Signal.sample model_source) "Filters") ~variant:`ghost ~width:40 ~height:44
          ~accessibility_identifier:("view.filter." ^ view.id) ~on_press:(fun _ -> Signal.set settings "filter") [];
        button ~icon:(`app "view-sort") ~label:(View_base.tr (Signal.sample model_source) "Sort") ~variant:`ghost ~width:40 ~height:44
          ~accessibility_identifier:("view.sort." ^ view.id) ~on_press:(fun _ -> Signal.set settings "sort") [];
        button ~icon:(`app "search") ~label:(View_base.tr (Signal.sample model_source) "Search results") ~variant:`ghost ~width:40 ~height:44
          ~accessibility_identifier:("view.search.toggle." ^ owner)
          ~on_press:(fun _ ->
            let was_open = Signal.sample (Signal.value search_open) in
            if was_open then Signal.set search "";
            Signal.set search_open (not was_open)) [];
        menu ~icon_signal:(own (Signal.map (fun view -> `app ("view-" ^ view.typ)) view_source))
          ~label:(View_base.tr (Signal.sample model_source) "View type") ~accessibility_identifier:("view.type." ^ view.id)
          ~disabled_signal:(waiting model_source view.id)
          ((if feature = "query-result" then [
            submenu ~text:(View_base.tr (Signal.sample model_source) "Saved views") [
              keyed ~source:views ~key:(fun view -> view.id) ~cmp:String.compare ~mount:(fun source ->
                let saved = Signal.sample source in
                menu_item ~text_signal:(own (Signal.map (fun view -> view.name) source))
                  ~selected:(saved.id = view.id) ~accessibility_identifier:("view.tab." ^ saved.id)
                  ~on_press:(fun _ -> Signal.set active saved.id) [])]
          ] else []) @ List.map (fun (typ, title) -> menu_item ~text:title ~icon:(`app ("view-" ^ typ))
            ~selected_signal:(own (Signal.map (fun view -> view.typ = typ) view_source))
            ~accessibility_identifier:("view.type.option." ^ view.id ^ "." ^ typ)
            ~on_press:(fun _ ->
              if (Signal.sample view_source).typ <> typ then ignore (send (Model.SubmitResultView
                (view.id, payload owner feature view.id "save" ["config", `Assoc ["type", `String typ; "name", `String (Signal.sample view_source).name]])))) [])
            ["list", "List"; "table", "Table"; "gallery", "Gallery"]);
      ];
      if_ ~test:(Signal.value search_open)
        (row ~cross:`center [search_field ~grow:1.0 ~text_signal:(Signal.value search) ~placeholder:(View_base.tr (Signal.sample model_source) "Search results") ~label:(View_base.tr (Signal.sample model_source) "Search results")
          ~accessibility_identifier:("view.search." ^ owner) ~on_input:(local_input (Signal.set search)) []]);

      if_ ~test:rows_loading (spinner ~accessibility_identifier:("view.rows.loading." ^ view.id) []);
      if_ ~test:(own (Signal.map ((<>) "") rows_error)) (row ~gap:8 [

        button ~text:(View_base.tr (Signal.sample model_source) "Refresh") ~variant:`ghost
          ~accessibility_identifier:("view.rows.retry." ^ view.id) ~on_press:(fun _ -> retry_rows ()) []]);

      if_ ~test:(own (Signal.map ((=) "") error))
        (column ~grow ~gap:8 [
          if_ ~test:(own (Signal.map2 (fun (view, rows) loading ->
            (if jfield "rowsDeferred" view.data = `Bool true then row_count view.data = 0 else rows = []) && not loading)
            (own (Signal.map2 (fun view rows -> view, rows) view_source rows)) rows_loading))
            (text ~value:(View_base.tr (Signal.sample model_source) "No results") ~foreground:"muted-foreground" ~accessibility_identifier:("query.empty." ^ owner) []);
          (dyn (fun (typ, columns, _, _) -> match typ with
          | "table" -> table_viewport ~fill_height ("view.table.scroll." ^ view.id) horizontal_viewport [
              column ~grow ~gap:0 ~cross:`stretch ~border_color:"border" ~border_width:1 ~corner_radius:10 [
                dyn (fun ((_, visible_columns, _) as window) -> row ~gap:0 ~cross:`stretch
                  (windowed_cells window (table_cells view.id "header" (List.map (fun col -> jtext (jfield "attr" col),
                    text ~value:(property_title (Signal.sample model_source) col) ~style_class:"subheadline single-line"
                    ~width:(table_column_width col) ~min_height:48 ~padding:12 ~background:"secondary" []) visible_columns)))) column_window;
                separator [];
                result_window ~identifier:("view.table.viewport." ^ view.id) ~extent:49
                  ~width:(List.fold_left (fun width col -> width +
                    (if jfield "attr" col = `String "block/title" then 260 else 170))
                    (max 0 (List.length columns - 1)) columns)
                  ~source:rows ~key:item_key
                  ~mount:(fun source -> column ~gap:0 [table_row source; separator []]) ()]]
          | "gallery" -> dyn (fun count ->
              result_window ~identifier:("view.gallery." ^ view.id) ~gap:12 ~columns:count
                ~extent:(96 + 24 * max 0 (List.length columns - 1))
                ~source:gallery_rows ~key:(fun items -> item_key (List.hd items))
                ~mount:(fun source grid_context parent -> (grid ~columns:count ~gap:12 [
                  keyed ~source ~key:item_key ~cmp:String.compare ~mount:gallery_card;
                  if_ ~test:(Signal.own_signal grid_context.Lui_ui.ui_scope
                    (Signal.map (fun items -> List.length items < count) source)) (box [])]) grid_context parent) ())
              gallery_columns
          | _ when fill_height || jfield "rowsDeferred" view.data = `Bool true ->
              result_window ~identifier:("query.rows." ^ owner) ~extent:64 ~source:rows ~key:item_key
                ~mount:(result_item owner render_block send) ()
          | _ -> column ~gap:4 ~accessibility_identifier:("query.rows." ^ owner) [
              keyed ~source:entries ~key:(fun item -> item.index) ~cmp:Int.compare ~mount:(result_item owner render_block send)]) layout);
          if_ ~test:(own (Signal.map2 (fun (view, rows) limit ->
              jfield "rowsDeferred" view.data <> `Bool true && view.typ <> "table" && view.typ <> "gallery" && List.length rows > limit)
              (own (Signal.map2 (fun view rows -> view, rows) view_source rows)) (Signal.value limit)))
            (button ~text:(View_base.tr (Signal.sample model_source) "Show more") ~variant:`ghost ~accessibility_identifier:("query.more." ^ owner)
              ~on_press:(fun _ -> Signal.set limit (Signal.sample (Signal.value limit) + 20)) [])]);
      if_ ~test:(own (Signal.map ((<>) "") (Signal.value settings)))
        (dyn (fun mode -> settings_sheet mode owner feature view_source model_source send (fun () -> Signal.set settings "")) (Signal.value settings));
      if_ ~test:(own (Signal.map Option.is_some (Signal.value editing)))
        (dyn (function None -> box [] | Some (item, property) ->
          value_sheet owner feature view model_source send item property (fun () -> Signal.set editing None)) (Signal.value editing));
    ]) context parent in
  (column ~grow ~gap:8 ~cross:`stretch ~accessibility_identifier:("query.block." ^ owner) [

    (if feature = "query-result" then
      if_ ~test:(own (Signal.map not (Signal.value expanded)))
        (row ~cross:`center ~accessibility_identifier:("view.toolbar." ^ owner) [results_toggle ()])
     else box []);

    if_ ~test:(Signal.value expanded) (column ~grow ~gap:8
      ([keyed ~source:chosen ~key:(fun view -> view.id) ~cmp:String.compare ~mount] @
       if fill_height then [] else [box ~height:24 ~accessibility_identifier:("view.results-gap." ^ owner) []]))]) context parent

let collection ?fill_height ~render_block model_source raw_source send : t = fun context parent ->
  let own value = Signal.own_signal context.Lui_ui.ui_scope value in
  let raw = own (Signal.cutoff String.equal raw_source) in
  let parsed = own (Signal.map (fun raw -> try Json.from_string raw with _ -> `Null) raw) in
  collection_json ?fill_height ~render_block model_source parsed send context parent

let view ~render_block model_source row_source send : t = fun context parent ->
  let own value = Signal.own_signal context.Lui_ui.ui_scope value in
  let raw_source = own (Signal.cutoff String.equal
    (own (Signal.map (fun (row : Model.outline_row) -> row.query_json) row_source))) in
  let parsed = own (Signal.map (fun raw -> try Json.from_string raw with _ -> `Null) raw_source) in
  (dyn (fun has_views ->
    if has_views then if_ ~test:(Signal.map (fun (row : Model.outline_row) -> not row.is_collapsed) row_source)
        (collection_json ~render_block model_source parsed send)
    else legacy_view ~render_block model_source row_source send)
    (own (Signal.cutoff Bool.equal (own (Signal.map (fun json -> saved_views_json json <> [] ||
      member "expanded" json <> None) parsed))))) context parent
