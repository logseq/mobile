open Lui_elements
module J = Yojson.Basic
let field name = function `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields) | _ -> `Null
let text = function `String value -> value | _ -> ""
let list = function `List values -> values | _ -> []
let decode raw = try J.from_string raw with _ -> `Null
let local_input set = function Lui_protocol.TextChanged (_, value) -> set value | _ -> ()
let has_properties raw = let source = decode raw in
  list (field "properties" source) <> [] || list (field "schemaProperties" source) <> []
let rename_page raw =
  let source = decode raw in
  let owner = text (field "ownerUuid" source) and property = field "rename" source in
  if owner <> "" && field "editable" property = `Bool true then Some (owner, property) else None

let tag_picker raw =
  let source = decode raw in
  let owner = text (field "ownerUuid" source) and property = field "tagPicker" source in
  if owner <> "" && property <> `Null then Some (owner, property) else None

let display_value property =
  let raw = text (field "text" property) in
  if field "kind" property <> `String "datetime" then raw else
  match float_of_string_opt (text (field "editorValue" property)) with
  | Some millis when Float.is_finite millis && abs_float millis <= 8640000000000000. ->
    let value = Unix.localtime (millis /. 1000.) in
    let now = Unix.localtime (Unix.gettimeofday ()) in
    let day t = t.Unix.tm_year, t.tm_mon, t.tm_mday in
    let noon, _ = Unix.mktime {now with tm_hour = 12; tm_min = 0; tm_sec = 0} in
    let date = if day value = day now then "Today"
      else if day value = day (Unix.localtime (noon +. 86400.)) then "Tomorrow"
      else if day value = day (Unix.localtime (noon -. 86400.)) then "Yesterday"
      else let months = [|"Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"; "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec"|] in
        Printf.sprintf "%s %d%s" months.(value.tm_mon) value.tm_mday
          (if value.tm_year = now.tm_year then "" else ", " ^ string_of_int (value.tm_year + 1900)) in
    Printf.sprintf "%s, %02d:%02d" date value.tm_hour value.tm_min
  | _ -> raw

let adaptive_row stacked children : t = fun context parent ->
  let node = Lui_ui.extension context "native-property-row" in
  attach context parent node;
  Lui_ui.extension_property_signal context node "stacked" (Signal.map (fun value -> Lui_protocol.BoolValue value) stacked);
  List.iter (fun child -> ignore (child context (Some node))) children;
  node

let with_add_property_picker model_source raw_source send render : t =
 fun context parent ->
  let own source = Signal.own_signal context.ui_scope source in
  let source = own (Signal.map decode raw_source) in
  let keys = own (Signal.map2 (fun (model : Model.logseq_model) json ->
    [Option.value ~default:"" model.selected_graph_id ^ ":" ^ text (field "ownerUuid" json)]) model_source source) in
  (keyed ~source:keys ~key:Fun.id ~cmp:String.compare ~mount:(fun _ -> fun context parent ->
    let own source = Signal.own_signal context.ui_scope source in
    let owner = text (field "ownerUuid" (Signal.sample source)) in
    let graph = Option.value ~default:"" (Signal.sample model_source).Model.selected_graph_id in
    let adding = Signal.state context.ui_scheduler false in
    let search = Signal.state context.ui_scheduler "" in
    let add_id = "property.add." ^ owner in
    let finished = ref None in
    ignore (Signal.own context.ui_scope (Signal.observe model_source (fun (model : Model.logseq_model) ->
      match List.find_opt (fun (key, _, _) -> key = add_id) model.result_view_feedback with
      | Some (_, revision, error) when !finished <> Some revision ->
        finished := Some revision; if error = None then Signal.set adding false
      | _ -> ())));
    let add fields = ignore (send (Model.SubmitNodeProperty (add_id,
      J.to_string (`Assoc (("blockUuid", `String owner) :: ("graphId", `String graph) :: fields))))) in
    let available = own (Signal.map2 (fun json query -> list (field "availableProperties" json)
      |> List.filter (fun property -> Outliner_state.includes_case_insensitive (text (field "title" property)) query)) source (Signal.value search)) in
    let can_create = own (Signal.map2 (fun json query ->
      let title = String.trim query in
      title <> "" && not (List.exists (fun name -> List.exists (fun property -> text (field "title" property) = title)
        (list (field name json))) ["availableProperties"; "properties"; "schemaProperties"])) source (Signal.value search)) in
    let action = if_ ~test:(own (Signal.map (fun json -> field "canAdd" json = `Bool true) source))
      (menu_item ~text:(View_base.tr (Signal.sample model_source) "Add property") ~accessibility_identifier:add_id
        ~on_press:(fun _ -> Signal.set search ""; Signal.set adding true) []) in
    let picker = if_ ~test:(Signal.value adding)
      (sheet ~text:(View_base.tr (Signal.sample model_source) "Add property") ~style_class:"navigation-list navigation-inline-title" ~detents:"medium,large"
        ~accessibility_identifier:(add_id ^ ".sheet") ~on_dismiss:(fun _ -> Signal.set adding false) [
        Lui_elements.list ~grow:1.0 ~style:`inset_grouped [
          search_field ~text_signal:(Signal.value search) ~placeholder:(View_base.tr (Signal.sample model_source) "Search or create a property") ~label:(View_base.tr (Signal.sample model_source) "Search properties")
            ~accessibility_identifier:(add_id ^ ".search") ~on_input:(local_input (Signal.set search)) [];
          list_section [keyed ~source:available ~key:(fun property -> text (field "attr" property)) ~cmp:String.compare
            ~mount:(fun property_source -> let property = Signal.sample property_source in
              let attr = text (field "attr" property) in
              list_item [button ~text:(text (field "title" property)) ~variant:`ghost ~text_alignment:`start ~min_height:44
                ~accessibility_identifier:("property.add.option." ^ owner ^ "." ^ attr)
                ~disabled_signal:(View_query.waiting model_source add_id)
                ~on_press:(fun _ -> add ["action", `String "add"; "attr", `String attr]) []])];
          if_ ~test:can_create
            (list_section [list_item [button ~text:(View_base.tr (Signal.sample model_source) "Create text property") ~variant:`ghost ~min_height:44
              ~accessibility_identifier:(add_id ^ ".create") ~disabled_signal:(View_query.waiting model_source add_id)
              ~on_press:(fun _ -> add ["action", `String "create"; "title", `String (String.trim (Signal.sample (Signal.value search)))]) []]]);
          View_query.action_error model_source add_id];
        toolbar ~label:(View_base.tr (Signal.sample model_source) "Property actions") ~style_class:"navigation-actions" [button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
          ~accessibility_identifier:(add_id ^ ".cancel") ~on_press:(fun _ -> Signal.set adding false) []]]) in
    (render action picker) context parent)) context parent

let view ?(compact = false) ~render_block model_source raw_source send : t =
 fun context parent ->
  let own source = Signal.own_signal context.ui_scope source in
  let source = own (Signal.map decode raw_source) in
  let owners = own (Signal.map (fun json -> let owner = text (field "ownerUuid" json) in
    if owner = "" || (list (field "properties" json) = [] && (compact || list (field "schemaProperties" json) = [])) then [] else [owner]) source) in
  (keyed ~source:owners ~key:Fun.id ~cmp:String.compare ~mount:(fun owner_source ->
    let owner = Signal.sample owner_source in
    let expanded = Signal.state context.ui_scheduler false in
    let all_properties = own (Signal.map (fun json -> list (field "properties" json)) source) in
    let properties = own (Signal.map2 (fun values expanded ->
      if expanded then values else List.filteri (fun index _ -> index < 3) values) all_properties (Signal.value expanded)) in
    let layout children = if compact then
      scroll ~orientation:`horizontal ~height:28 ~accessibility_identifier:("properties." ^ owner)
        [row ~gap:16 ~cross:`center children]
      else column ~gap:2 ~padding_horizontal:16 ~margin_bottom:12 ~cross:`stretch
        ~accessibility_identifier:("properties." ^ owner) children in
    View_base.with_string_prop Lui_protocol.FontSize (if compact then "14" else "16") (layout [
      keyed ~source:properties ~key:(fun property -> text (field "attr" property)) ~cmp:String.compare
        ~mount:(fun property_source -> fun context parent ->
          let own source = Signal.own_signal context.ui_scope source in
          let first = Signal.sample property_source in
          let attr = text (field "attr" first) in
          let id = "property." ^ owner ^ "." ^ attr in
          let editing = Signal.state context.ui_scheduler None in
          let checked_value p = field "value" (field "raw" p) = `Bool true in
          let checked = Signal.state context.ui_scheduler (checked_value first) in
          let previous_raw = ref (field "raw" first) in
          ignore (Signal.own context.ui_scope (Signal.observe property_source (fun property ->
            let raw = field "raw" property in
            if raw <> !previous_raw then (previous_raw := raw; Signal.set checked (checked_value property)))));
          let finished = ref None in
          ignore (Signal.own context.ui_scope (Signal.observe model_source (fun (model : Model.logseq_model) ->
            match List.find_opt (fun (key, _, _) -> key = id) model.result_view_feedback with
            | Some (_, revision, error) when !finished <> Some revision ->
              finished := Some revision;
              Signal.set checked (checked_value (Signal.sample property_source));
              if error = None then Signal.set editing None
            | _ -> ())));
          let edit () =
            let property = Signal.sample property_source in
            if field "editable" property = `Bool true then Signal.set editing (Some property) in
          let submit fields = ignore (send (Model.SubmitNodeProperty (id,
            J.to_string (`Assoc (("blockUuid", `String owner) :: fields))))) in
          let send_block = function
            | (Model.BeginOutlinerEdit _ | Model.BeginOutlinerEditAt _) as action ->
              if field "editable" (Signal.sample property_source) = `Bool true then send action else true
            | action -> send action in
          let task_icon = match compact, attr with true, "logseq.property/scheduled" -> Some "calendar"
            | true, "logseq.property/deadline" -> Some "deadline" | _ -> None in
          let label = match task_icon with
            | Some name -> icon ~name:(`app name) ~width:20 ~height:20 ~foreground:"muted-foreground"
                ~tooltip:(text (field "title" first))
                ~accessibility_identifier:("property.label." ^ owner ^ "." ^ attr) []
            | None -> Lui_elements.text ~value_signal:(own (Signal.map (fun p -> text (field "title" p)) property_source))
            ~foreground:"muted-foreground" ~style_class:"callout" ~text_alignment:`start
            ~accessibility_identifier:("property.label." ^ owner ^ "." ^ attr) [] in
          let value = button ~variant:`ghost ~foreground:"muted-foreground" ~text_alignment:`start
            ~min_height:(if compact then 28 else 32) ~padding_horizontal:0 ~padding_vertical:0 ~grow:(if compact then 0.0 else 1.0)
            ~text_signal:(own (Signal.map (fun p -> let value = display_value p in if value = "" then "Empty" else value) property_source))
            ~label:(text (field "title" first)) ~disabled:(field "editable" first <> `Bool true)
            ~accessibility_identifier:("property.value." ^ owner ^ "." ^ attr) ~on_press:(fun _ -> edit ()) [] in
          let node_value = dyn (fun property -> match list (field "references" property) with
            | [] -> value
            | references -> column ~gap:2 ~grow:1.0
                ~accessibility_identifier:("property.reference." ^ owner ^ "." ^ attr)
                (List.mapi (fun index reference ->
                  let uuid = text (field "uuid" reference) in
                  button ~text:(text (field "title" reference)) ~variant:`ghost ~text_alignment:`start
                    ~padding_horizontal:0 ~padding_vertical:0 ~foreground:"primary" ~min_width:44
                    ~min_height:(if compact then 28 else 44)
                    ~accessibility_identifier:("property.value." ^ owner ^ "." ^ attr ^ (if index = 0 then "" else "." ^ uuid))
                    ~on_press:(fun _ -> if field "editable" property = `Bool true then edit ()
                      else ignore (send (Model.RequestAppNode uuid)))
                    ~on_long_press:(fun _ -> ignore (send (Model.RequestAppNode uuid))) []) references)) property_source in
          let checkbox_value = checkbox ~foreground:"muted-foreground" ~width:32 ~height:32
            ~checked_signal:(Signal.value checked)
            ~disabled_signal:(own (Signal.map2 (fun property model -> field "editable" property <> `Bool true || List.exists (function
              | Model.NodePropertyEffect (_, key, _) -> key = id | _ -> false) (model.Model.pending_effects @ model.in_flight_effects)) property_source model_source))
            ~label:(text (field "title" first)) ~accessibility_identifier:("property.value." ^ owner ^ "." ^ attr)
            ~on_toggle:(function Lui_protocol.ToggleChanged (_, value) ->
              Signal.set checked value;
              submit ["attr", `String attr; "expected", field "raw" (Signal.sample property_source);
                "value", `String (string_of_bool value)] | _ -> ()) [] in
          let fields children = if compact then row ~gap:6 ~cross:`center children
            else adaptive_row (own (Signal.map (fun p -> field "textLayout" p = `Bool true) property_source)) children in
          (column ~gap:2 ~cross:(if compact then `start else `stretch) [
            fields [
              label;
              dyn (fun text_layout -> if text_layout then
                dyn (fun empty -> if empty then row [value] else box ~opacity:0.72 [
                  View_query.block_values ~render_block owner (own (Signal.map (fun p ->
                    match list (field "blocks" p) with
                    | [] -> `List [`Assoc ["uuid", `String id; "title", field "text" p;
                        "markup", field "markup" p; "pageId", `String owner]]
                    | blocks -> `List blocks) property_source)) send_block])
                  (own (Signal.map (fun p -> list (field "blocks" p) = [] && text (field "text" p) = "") property_source))
                else row ~gap:0 ~cross:`center ~accessibility_identifier:("property.inline." ^ owner ^ "." ^ attr) [
                  if field "kind" first = `String "checkbox" then checkbox_value else node_value])
                (own (Signal.map (fun p -> field "textLayout" p = `Bool true) property_source));
            ];
            if_ ~test:(own (Signal.map Option.is_some (Signal.value editing)))
              (dyn (function None -> box [] | Some property ->
                let open_nodes = List.map (fun reference ->
                  let uuid = text (field "uuid" reference) in
                  uuid, "Open “" ^ text (field "title" reference) ^ "”", (fun () -> ignore (send (Model.RequestAppNode uuid))))
                  (list (field "references" property)) in
                View_query.property_editor ~open_nodes ~id ~column:property
                ~submit:(fun fields -> submit (("textValueUuid", field "textValueUuid" property) :: fields))
                model_source property (fun () -> Signal.set editing None)) (Signal.value editing));
            if_ ~test:(own (Signal.map Option.is_none (Signal.value editing))) (View_query.action_error model_source id);
          ]) context parent);
      if_ ~test:(own (Signal.map (fun values -> List.length values > 3) all_properties))
        (button ~variant:`ghost ~foreground:"muted-foreground" ~text_alignment:`start ~min_height:32 ~padding:0
          ~icon_signal:(own (Signal.map (fun expanded -> `app (if expanded then "chevron-up" else "chevron-down")) (Signal.value expanded)))
          ~text_signal:(own (Signal.map (fun expanded -> if expanded then "Collapse" else "Expand") (Signal.value expanded)))
          ~accessibility_identifier:("properties.expand." ^ owner)
          ~on_press:(fun _ -> Signal.set expanded (not (Signal.sample (Signal.value expanded)))) []);
      (if compact then box [] else
        if_ ~test:(own (Signal.map (fun json -> list (field "schemaProperties" json) <> []) source))
          (column ~gap:2 ~cross:`stretch [
            Lui_elements.text ~value:(View_base.tr (Signal.sample model_source) "Tag properties") ~foreground:"muted-foreground" ~style_class:"callout" [];
            keyed ~source:(own (Signal.map (fun json -> list (field "schemaProperties" json)) source))
              ~key:(fun property -> text (field "attr" property)) ~cmp:String.compare ~mount:(fun property_source ->
                Lui_elements.text ~value_signal:(own (Signal.map (fun property -> text (field "title" property)) property_source))
                  ~min_height:32 ~accessibility_identifier:("property.schema." ^ owner ^ "." ^ text (field "attr" (Signal.sample property_source))) [])]));
    ]))) context parent
