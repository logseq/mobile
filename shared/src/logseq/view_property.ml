open Lui_elements
module J = Yojson.Basic
let field name = function `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields) | _ -> `Null
let text = function `String value -> value | _ -> ""
let list = function `List values -> values | _ -> []
let decode raw = try J.from_string raw with _ -> `Null
let has_properties raw = list (field "properties" (decode raw)) <> []

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

let view ?(compact = false) ~render_block model_source raw_source send : t =
 fun context parent ->
  let own source = Signal.own_signal context.ui_scope source in
  let source = own (Signal.map decode raw_source) in
  let owners = own (Signal.map (fun json -> let owner = text (field "ownerUuid" json) in
    if owner = "" || list (field "properties" json) = [] then [] else [owner]) source) in
  (keyed ~source:owners ~key:Fun.id ~cmp:String.compare ~mount:(fun owner_source ->
    let owner = Signal.sample owner_source in
    let expanded = Signal.state context.ui_scheduler false in
    let all_properties = own (Signal.map (fun json -> list (field "properties" json)) source) in
    let properties = own (Signal.map2 (fun values expanded ->
      if expanded then values else List.filteri (fun index _ -> index < 3) values) all_properties (Signal.value expanded)) in
    View_base.with_string_prop Lui_protocol.FontSize (if compact then "14" else "16") (column ~gap:(if compact then 0 else 2) ~padding_horizontal:(if compact then 0 else 16) ~margin_bottom:(if compact then 0 else 12) ~cross:`stretch
      ~accessibility_identifier:("properties." ^ owner) [
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
          let edit ?value_uuid () =
            let property = Signal.sample property_source in
            if field "editable" property = `Bool true then (
              let value = Option.bind value_uuid (fun uuid -> List.find_opt (fun block -> field "uuid" block = `String uuid) (list (field "blocks" property))) in
              let property = match value, property with
                | Some block, `Assoc fields -> `Assoc (("text", field "title" block) ::
                    ("textValueUuid", field "uuid" block) :: List.remove_assoc "text" fields)
                | _ -> property in
              Signal.set editing (Some property)) in
          let submit fields = ignore (send (Model.SubmitNodeProperty (id,
            J.to_string (`Assoc (("blockUuid", `String owner) :: fields))))) in
          let send_block = function
            | Model.BeginOutlinerEdit uuid -> edit ~value_uuid:uuid (); true
            | action -> send action in
          let task_icon = match attr with "logseq.property/scheduled" -> Some "calendar"
            | "logseq.property/deadline" -> Some "deadline" | _ -> None in
          let label = match task_icon with
            | Some name -> icon ~name:(`app name) ~width:20 ~height:20 ~foreground:"muted-foreground"
                ~tooltip:(text (field "title" first))
                ~accessibility_identifier:("property.label." ^ owner ^ "." ^ attr) []
            | None -> Lui_elements.text ~value_signal:(own (Signal.map (fun p -> text (field "title" p)) property_source))
            ~foreground:"muted-foreground" ~style_class:"callout" ~text_alignment:`start
            ~accessibility_identifier:("property.label." ^ owner ^ "." ^ attr) [] in
          let value = button ~variant:`ghost ~foreground:"muted-foreground" ~text_alignment:`start
            ~min_height:(if compact then 28 else 32) ~padding_horizontal:0 ~padding_vertical:0 ~grow:1.0
            ~text_signal:(own (Signal.map (fun p -> let value = display_value p in if value = "" then "Empty" else value) property_source))
            ~label:(text (field "title" first)) ~disabled:(field "editable" first <> `Bool true)
            ~accessibility_identifier:("property.value." ^ owner ^ "." ^ attr) ~on_press:(fun _ -> edit ()) [] in
          let checkbox_value = checkbox ~foreground:"muted-foreground" ~width:32 ~height:32
            ~checked_signal:(Signal.value checked)
            ~disabled_signal:(own (Signal.map2 (fun property model -> field "editable" property <> `Bool true || List.exists (function
              | Model.NodePropertyEffect (_, key, _) -> key = id | _ -> false) (model.Model.pending_effects @ model.in_flight_effects)) property_source model_source))
            ~label:(text (field "title" first)) ~accessibility_identifier:("property.value." ^ owner ^ "." ^ attr)
            ~on_toggle:(function Lui_protocol.ToggleChanged (_, value) ->
              Signal.set checked value;
              submit ["attr", `String attr; "expected", field "raw" (Signal.sample property_source);
                "value", `String (string_of_bool value)] | _ -> ()) [] in
          (column ~gap:2 ~cross:`stretch [
            adaptive_row (own (Signal.map (fun p -> field "textLayout" p = `Bool true) property_source)) [
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
                  if field "kind" first = `String "checkbox" then checkbox_value else value])
                (own (Signal.map (fun p -> field "textLayout" p = `Bool true) property_source));
            ];
            if_ ~test:(own (Signal.map Option.is_some (Signal.value editing)))
              (dyn (function None -> box [] | Some property -> View_query.property_editor ~id ~column:property
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
    ]))) context parent
