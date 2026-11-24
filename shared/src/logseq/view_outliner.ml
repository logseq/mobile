open Lui_protocol
open Lui_elements

let journal_task_field = View_rows.task_field
let task_text = function `String value -> value | _ -> ""

let task_date_fields = ["scheduled", "Scheduled", "calendar"; "deadline", "Deadline", "deadline"]

let task_effect_active key (current : Model.logseq_model) =
  List.exists (function
    | Model.NodePropertyEffect (_, id, _) | Model.LoadPropertyValuesEffect (_, id, _) -> id = key
    | _ -> false) (current.pending_effects @ current.in_flight_effects)

let task_dates_dialog model_source send : t =
  let close () = ignore (send Model.CloseTaskDates) in
  reactive (function
    | None -> box []
    | Some (editor : Model.task_date_editor) ->
      custom @@ fun context parent ->
      let key = editor.task_date_key in
      let graph = editor.task_date_graph in
      let blocks = editor.task_date_targets in
      let editing = editor.task_date_editing in
      let name, field_label, _ =
        List.find (fun (name, _, _) -> name = editor.task_date_field) task_date_fields in
      let own signal = Signal.own_signal context.Lui_ui.ui_scope signal in
      let state initial = Signal.state context.ui_scheduler initial in
      let current = Signal.sample model_source in
      let tr = View_base.tr current in
      let waiting = own (Signal.map (task_effect_active key) model_source) in
      let feedback = own (Signal.map (fun (current : Model.logseq_model) ->
        List.find_map (fun (id, _, error) -> if key = id then error else None) current.result_view_feedback) model_source) in
      let loaded = own (Signal.map (fun (current : Model.logseq_model) ->
        match List.assoc_opt key current.property_value_catalogs with
        | Some data -> (match journal_task_field "targets" (Yojson.Basic.from_string data) with
          | `List targets -> Some targets | _ -> None)
        | None -> None) model_source) in
      let saved_dates = own (Signal.map (Option.fold ~none:[] ~some:(fun targets ->
        List.map (journal_task_field name) targets |> List.sort_uniq compare)) loaded) in
      let submit value =
        match Signal.sample loaded with
        | Some targets when not (Signal.sample waiting) ->
          let current = Signal.sample model_source in
          let collapsed = match editing, current.outliner_edit_scope with
            | Some uuid, Some (scope, target) when target = uuid && scope = View_rows.journal_task_scope uuid ->
              `List (List.map (fun name -> `String name) (Model.journal_tasks_collapsed current))
            | _ -> `Null in
          let payload = Yojson.Basic.to_string (`Assoc [
            "action", `String "saveTaskDates"; "graphId", `String graph;
            "editingUuid", Option.fold ~none:`Null ~some:(fun uuid -> `String uuid) editing;
            "agendaCollapsedSections", collapsed;
            "targets", `List targets; "changes", `Assoc [name, value]]) in
          ignore (send (Model.SubmitNodeProperty (key, payload)))
        | _ -> () in
      if Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost then begin
        let node = Lui_ui.extension context "native-task-date-sheet" in
        attach context parent node;
        let invalid = state false in
        let dates = own (Signal.map2 (fun saved loaded -> saved, Option.is_some loaded) saved_dates loaded) in
        let error = own (Signal.map2 (fun error invalid ->
          let error = if invalid then Some (tr "Choose a valid date and time") else Option.map tr error in
          Option.fold ~none:`Null ~some:(fun error -> `String error) error)
          feedback (Signal.value invalid)) in
        let status = own (Signal.map2 (fun waiting error -> waiting, error) waiting error) in
        let payload = own (Signal.map2 (fun (saved, ready) (waiting, error) ->
          StringValue (Yojson.Basic.to_string (`Assoc [
            "title", `String (tr field_label); "clearTitle", `String (tr "Clear" ^ " " ^ tr field_label);
            "submitTitle", `String (tr "Save"); "mixedTitle", `String (tr "Mixed dates");
            "value", (match saved with [(`Int _ as value)] -> value | _ -> `Null);
            "ready", `Bool ready; "waiting", `Bool waiting;
            "canClear", `Bool (List.exists (fun value -> value <> `Null) saved);
            "mixed", `Bool (List.length saved > 1);
            "error", error
          ]))) dates status) in
        Lui_ui.extension_property_signal context node "payload" payload;
        let apply value =
          if Option.is_some (Signal.sample loaded) && not (Signal.sample waiting) then begin
            Signal.set invalid false;
            if Signal.sample saved_dates = [value] then close () else submit value
          end in
        Lui_ui.on_event context node (function
          | ExtensionEvent (_, _, "dismiss", _) -> close ()
          | ExtensionEvent (_, _, "clear", _) -> apply `Null
          | ExtensionEvent (_, _, "choose", fields) ->
            (match String_map.find_opt "value" fields with
             | Some (StringValue value) ->
               Option.iter (fun day -> apply (`Assoc ["day", `Int day])) (int_of_string_opt value)
             | _ -> ())
          | ExtensionEvent (_, _, "submit", fields) ->
            (match String_map.find_opt "value" fields with
             | Some (StringValue text) ->
               let current = Signal.sample model_source in
               let locale = if current.language = "system" then current.system_language else current.language in
               (match Natural_date.timestamp ~locale ~full_match:true text with
                | Some value -> apply (`Int value)
                | None -> Signal.set invalid true)
             | _ -> ())
          | _ -> ());
        node
      end else
      let draft = state None in
      let input = state "" in
      let input_valid = state true in
      let midnight = Session_types.now_ms () |> Cache_model.journal_day_for_ms
        |> Dev_query.Date_time_util.journal_day_to_local_ms |> Int64.to_int in
      let pending = own (Signal.map2 (fun saved edit ->
        match saved, edit with
        | [], _ -> None
        | [value], Some edit when value = edit -> None
        | _, Some edit -> Some edit
        | [`Null], None -> Some (`Int midnight)
        | _ -> None) saved_dates (Signal.value draft)) in
      let save () =
        if Signal.sample (Signal.value input_valid) then Option.iter submit (Signal.sample pending) in
      let picker_value = own (Signal.map2 (fun saved edit ->
        match saved, edit with
        | _, Some (`Int value) | [`Int value], None -> string_of_int value
        | _ -> string_of_int midnight) saved_dates (Signal.value draft)) in
      let clear_disabled = own (Signal.map2 (fun saved edit ->
        edit = Some `Null || (edit = None && saved = [`Null]))
        saved_dates (Signal.value draft)) in
      let error_message = reactive (function None -> box [] | Some error ->
        text ~foreground:"destructive" ~style_class:"footnote" ~value:(tr error) []) feedback in
      let controls = column ~gap:12 [
        View_query.temporal_picker ~input ~on_validity:(Signal.set input_valid)
          model_source "datetime" ("task-dates." ^ name) picker_value
          (fun value -> Option.iter (fun value -> Signal.set draft (Some (`Int value))) (Natural_date.timestamp value));
        if_ ~test:(own (Signal.map not (Signal.value input_valid)))
          (text ~foreground:"destructive" ~style_class:"footnote" ~value:(tr "Choose a valid date and time") []);
        if_ ~test:(own (Signal.map2 (fun saved edit -> List.length saved > 1 && edit = None)
          saved_dates (Signal.value draft)))
          (text ~style_class:"footnote" ~value:(tr "Mixed dates") []);
        error_message;
        button ~variant:`ghost ~min_height:44 ~text:(tr "Clear")
          ~disabled_signal:clear_disabled ~accessibility_identifier:("task-dates.clear." ^ name)
          ~on_press:(fun _ ->
            Signal.set input "";
            Signal.set input_valid true;
            Signal.set draft (Some `Null)) [];
      ] in
      let cancel = toolbar_button ~text:(tr "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
        ~accessibility_identifier:"task-dates.cancel" ~on_press:(fun _ -> close ()) [] in
      let unavailable = own (Signal.map2 (fun waiting pending -> waiting || pending = None) waiting pending) in
      let disabled = own (Signal.map2 (fun unavailable valid -> unavailable || not valid)
        unavailable (Signal.value input_valid)) in
      let save_button = toolbar_button ~text:(tr "Save") ~variant:`ghost ~style_class:"confirmation-action"
        ~accessibility_identifier:"task-dates.save" ~disabled_signal:disabled ~on_press:save [] in
      mount context ?parent (View_base.sheet ~model_source ~title:(tr field_label)
        ~detents:"large"
        ~style_class:"navigation-list navigation-inline-title" ~accessibility_identifier:"sheet.task-dates"
        ~on_dismiss:(fun _ -> close ()) [
          list ~grow:1.0 ~style:`inset_grouped [
            list_section [
              if_list_section_item ~test:(Signal.constant context.ui_scheduler (List.length blocks > 1))
                (list_section_item [text ~value:(View_base.tr_named current "{1} blocks selected"
                  (string_of_int (List.length blocks))) ~style_class:"footnote" []]);
              list_section_item [reactive (function
                | Some _ -> controls
                | None -> column [
                  if_ ~test:waiting (spinner ~accessibility_identifier:"task-dates.loading" []);
                  error_message;
                ]) loaded];
            ];
          ];
          (if Lui_ui.host context = KotlinHost then row ~main:`space_between ~padding:12 [
             button ~text:(tr "Cancel") ~on_press:(fun _ -> close ()) [];
             button ~text:(tr "Save") ~disabled_signal:disabled ~accessibility_identifier:"task-dates.save"
               ~on_press:(fun _ -> save ()) []]
           else toolbar ~label:(tr "Task dates") ~style_class:"navigation-actions" [cancel; save_button]);
        ]))
    (Signal.map (fun (current : Model.logseq_model) -> current.task_date_editor) model_source)

let code_language row =
    try match Yojson.Basic.from_string row.Model.markup_json with
      | `List (`Assoc fields :: _) -> (match List.assoc_opt "style" fields with Some (`String language) -> language | _ -> "")
      | _ -> "" with _ -> ""

let outliner_editor_view model_source block_id_source title_source caret_source send : t
    =
 custom @@ fun context parent ->
   let node = Lui_ui.extension context "outliner-editor" in
   attach context parent node;
   Lui_ui.extension_property_signal context node "input-policy"
     (Signal.map2 (fun (current : Model.logseq_model) uuid ->
       let row = List.find_opt (fun (row : Model.outline_row) -> row.row_uuid = uuid) current.outliner_rows in
       let display_type = Option.bind row (fun row -> row.Model.row_display_type) in
       let special = List.mem display_type [Some "code"; Some "math"] in
       StringValue (if special then Yojson.Basic.to_string (`Assoc [
         "multiline", `Bool (display_type = Some "code"); "code", `Bool (display_type = Some "code");
         "language", `String (Option.fold ~none:"" ~some:code_language row);
         "emptyPairs", `List [`Assoc ["text", `String "[[]]"; "deleteOffset", `Int 1]]])
         else Outliner_state.native_input_policy)) model_source block_id_source);
   Lui_ui.extension_property_signal context node "focus-enabled"
     (Signal.map (fun (current : Model.logseq_model) -> BoolValue
       (current.task_date_editor = None && match current.outliner_autocomplete with
        | Some {autocomplete_kind = Model.PickerAutocomplete _; _} -> false
        | _ -> true)) model_source);
   Lui_ui.extension_property_signal context node "selection-revision"
     (Signal.map (fun (current : Model.logseq_model) ->
       IntValue current.outliner_selection_revision) model_source);
   Lui_ui.extension_property_signal context node "block-id"
     (Signal.map View_base.string_wire_value block_id_source);
   Lui_ui.extension_property_signal context node "title"
     (Signal.map View_base.string_wire_value title_source);
   Lui_ui.extension_property_signal context node "caret-utf16-offset"
     (Signal.map View_base.int_wire_value caret_source);
   Lui_ui.on_event context node (fun input_event ->
       ignore
         (View_base.handle_outliner_editor_event input_event
            block_id_source send));
   node

let row_metadata (row : Model.outline_row) =
  try Yojson.Basic.from_string row.row_metadata_json with _ -> `Null

let metadata_member key row =
  match row_metadata row with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields) | _ -> `Null

let block_menu_labels current =
  `Assoc (List.map (fun label -> label, `String (View_base.tr current label))
    ["Open block"; "Edit"; "Scheduled"; "Deadline"; "Status"; "Copy"; "Cut"; "Copy reference"; "Copy URL";
     "Move"; "Move up"; "Move down"; "Outdent"; "Indent"; "Delete"; "Select"; "Unselect"])

let handle_block_menu_event model_source row_source send = function
  | ExtensionEvent (_, _, "menu-action", values) ->
    let row : Model.outline_row = Signal.sample row_source in
    (match String_map.find_opt "payload" values with
     | Some (StringValue "open") ->
       let uuid = Option.value ~default:row.row_uuid row.row_embed_source_uuid in
       ignore (send (View_base.request_node_action (Signal.sample model_source) uuid))
     | Some (StringValue ("scheduled" | "deadline" as field)) ->
       if metadata_member "isTask" row = `Bool true then
         ignore (send (Model.OpenBlockTaskDate (row.row_uuid, field)))
     | Some (StringValue action) -> ignore (send (Model.PerformOutlinerBlockAction (row.row_uuid, action)))
     | _ -> ())
  | ExtensionEvent (_, _, "set-status", values) ->
    (match String_map.find_opt "count" values with
     | Some (IntValue index) when index >= 0 ->
       Option.iter (fun (status : Model.task_status) ->
         ignore (send (Model.SetOutlinerTaskStatus ((Signal.sample row_source).row_uuid, status.uuid))))
         (List.nth_opt (Signal.sample model_source).Model.task_statuses index)
     | _ -> ())
  | input -> ignore (View_base.handle_outliner_block_content_event input model_source send)

let outliner_rich_block_view ?(show_code_language = true) model_source title_source markup_source
    youtube_target_source is_asset_source row_source asset_type_source
    local_path_source send : t =
 custom @@ fun context parent ->
   let node = Lui_ui.extension context "outliner-block-content" in
   attach context parent node;
   Lui_ui.extension_property context node "show-code-language" (BoolValue show_code_language);
   Lui_ui.extension_property_signal context node "block-id"
     (Signal.map View_base.outliner_row_id_wire_value row_source);
   Lui_ui.extension_property_signal context node "title"
     (Signal.map View_base.string_wire_value title_source);
   Lui_ui.extension_property_signal context node "markup-json"
     (Signal.map View_base.string_wire_value markup_source);
   Lui_ui.extension_property_signal context node "youtube-target-url"
     (Signal.map View_base.string_wire_value youtube_target_source);
   Lui_ui.extension_property_signal context node "is-asset"
     (Signal.map View_base.bool_wire_value is_asset_source);
   Lui_ui.extension_property_signal context node "is-completed"
     (Signal.map View_base.outliner_row_completed_wire_value row_source);
   Lui_ui.extension_property_signal context node "asset-type"
     (Signal.map View_base.string_wire_value asset_type_source);
   Lui_ui.extension_property_signal context node "local-path"
     (Signal.map View_base.string_wire_value local_path_source);
   if Lui_ui.host context = KotlinHost then
     Lui_ui.extension_property_signal context node "row-actions"
       (Signal.map2 (fun current row ->
         let is_task = metadata_member "isTask" row = `Bool true in
         let statuses = if not is_task then [] else
           List.map (fun (status : Model.task_status) -> `Assoc [
             "title", `String status.title;
             "icon", `String (View_base.task_status_icon_name status);
             "foreground", `String (View_base.task_status_foreground status);
           ]) current.Model.task_statuses in
         StringValue (Yojson.Basic.to_string (`Assoc [
           "selectionMode", `Bool (View_base.outliner_selection_active_ current);
           "isTask", `Bool is_task;
           "statuses", `List statuses;
           "labels", block_menu_labels current;
         ]))) model_source row_source);
   Lui_ui.on_event context node (handle_block_menu_event model_source row_source send);
   node

let outliner_collapse_button (context : Lui_ui.ui_context) model_source row_source
    send : t =
  let current_row = Signal.sample row_source in
  let current = Signal.sample model_source in
  if Lui_ui.host context = KotlinHost then
    View_base.with_label_signal
      (Signal.map2 View_base.outliner_row_collapse_label model_source row_source)
      (View_base.with_string_prop_signal InlineIconName
         (Signal.map
            (fun (current_row : Model.outline_row) ->
              View_base.outliner_collapse_icon_name
                current_row.is_collapsed)
            row_source)
         (icon_button ~icon:(`app "disclosure-right") ~label:(View_base.outliner_row_collapse_label current current_row) ~variant:`ghost ~width:24 ~height:24
            ~accessibility_identifier:
              (View_base.outliner_collapse_identifier current_row)
            ~on_press:(fun _ ->
              ignore
                (send
                   (Model.ToggleOutlinerCollapsed
                      (Signal.sample row_source : Model.outline_row).row_uuid)))
            []))
  else
    View_base.with_label_signal
      (Signal.map2 View_base.outliner_row_collapse_label model_source row_source)
      (View_base.with_string_prop_signal InlineIconName
         (Signal.map
            (fun (current_row : Model.outline_row) ->
              if current_row.is_collapsed then "app:disclosure-right"
              else "app:disclosure-down")
            row_source)
         (icon_button ~icon:(`app "disclosure-right") ~label:(View_base.outliner_row_collapse_label current current_row) ~size:`icon ~style_class:"body-line"
            ~foreground:"secondary" ~variant:`ghost ~width:44 ~height:44
            ~accessibility_identifier:
              (View_base.outliner_collapse_identifier current_row)
            ~on_press:(fun _ ->
              ignore
                (send
                   (Model.ToggleOutlinerCollapsed
                      (Signal.sample row_source : Model.outline_row).row_uuid)))
            []))

let outliner_indent_view width_source : t =
 custom @@ fun context parent ->
   let node = Lui_ui.text context "" in
   attach context parent node;
   Lui_ui.int_property_signal context node WidthValue width_source;
   node

let breadcrumb_button breadcrumb_source search_open send : t =
  let breadcrumb = Signal.sample breadcrumb_source in
  button
    ~text:(reactive View_base.breadcrumb_title breadcrumb_source)
    ~variant:`ghost ~style_class:"caption single-line" ~padding:0 ~height:28 ~foreground:"muted-foreground"
    ~accessibility_identifier:(View_base.breadcrumb_identifier breadcrumb)
    ~on_press:(fun _ ->
      ignore
        (send
           (if search_open then
              Model.RequestSearchNode
                (Signal.sample breadcrumb_source : Model.sidebar_page).uuid
            else
              Model.RequestAppNode
                (Signal.sample breadcrumb_source : Model.sidebar_page).uuid)))
    []

let node_breadcrumb_button model_source breadcrumb_source send : t =
  let search_open = (Signal.sample model_source : Model.logseq_model).search_open in
  breadcrumb_button breadcrumb_source search_open send

let node_breadcrumbs model_source send : t =
  scroll ~orientation:`horizontal ~height:32 ~padding_horizontal:16
    [ breadcrumb ~gap:6 ~main:`start
    ~accessibility_identifier:"breadcrumb.node"
    [
      keyed
        ~source:(Signal.map View_base.active_node_breadcrumbs model_source)
        ~key:View_base.breadcrumb_identifier ~cmp:compare
        ~mount:(fun breadcrumb_source ->
          node_breadcrumb_button model_source breadcrumb_source send);
    ]
    ]

let related_row_breadcrumbs model_source row_source send : t =
  breadcrumb ~gap:5 ~main:`start
    ~accessibility_identifier:"breadcrumb.related-blocks"
    [
      keyed
        ~source:(Signal.map View_base.outliner_row_breadcrumbs row_source)
        ~key:View_base.breadcrumb_identifier ~cmp:compare
        ~mount:(fun breadcrumb_source ->
          node_breadcrumb_button model_source breadcrumb_source send);
    ]

let remove_node_tag current owner tag =
  Model.SubmitNodeProperty ("tag.remove." ^ owner ^ "." ^ tag,
    Yojson.Basic.to_string (`Assoc ["blockUuid", `String owner; "action", `String "removeTag";
      "tagUuid", `String tag; "graphId", `String (Option.value ~default:"" current.Model.selected_graph_id)]))

let outliner_tag model_source owner tag_source send : t =
  let tag = Signal.sample tag_source in
  View_base.with_label_signal
    (Signal.map View_base.outliner_tag_title tag_source)
    (button
       ~text:(reactive View_base.outliner_tag_title tag_source)
       ~style_class:"caption" ~variant:`ghost ~foreground:"link"
       ~height:22 ~padding_vertical:0
       ~accessibility_identifier:(View_base.outliner_tag_identifier tag)
       ~on_press:(fun _ ->
         ignore
           (send
              (View_base.request_node_action (Signal.sample model_source)
                (Signal.sample tag_source : Model.sidebar_page).uuid)))
       [context_menu [if_context_menu_item ~test:(Signal.map (fun current -> Model.node_can_set_tags current owner) model_source)
         (context_menu_item ~text:(View_base.tr (Signal.sample model_source) "Remove tag") ~variant:`destructive
           ~accessibility_identifier:("button.block-tag.remove." ^ owner ^ "." ^ tag.uuid)
           ~on_press:(fun _ -> ignore (send (remove_node_tag (Signal.sample model_source) owner tag.uuid))) ())]])

let outliner_zoom_control (context : Lui_ui.ui_context) model_source
    row_source send : t =
  let current_row = Signal.sample row_source in
  let on_press _ =
    let row : Model.outline_row = Signal.sample row_source in
    let uuid = Option.value ~default:row.row_uuid row.row_embed_source_uuid in
    ignore (send (View_base.request_node_action (Signal.sample model_source) uuid)) in
  if Lui_ui.host context = KotlinHost then
    stack ~width:24 ~height:24
      [
        row ~width:24 ~height:24 ~main:`center ~cross:`center
          [
            if_ ~test:(Signal.map (fun (row : Model.outline_row) -> row.row_list_number <> None && not row.row_is_embed) row_source)
              (text ~value:(reactive (fun (row : Model.outline_row) ->
                Option.fold ~none:"" ~some:(fun n -> string_of_int n ^ ".") row.row_list_number) row_source)
                ~font_size:"14" ~foreground:"muted-foreground"
                ~accessibility_identifier:("outliner.number." ^ View_base.outliner_row_uuid current_row) []);
            View_base.node_icon_view ~size:18 (Signal.map2 (fun current (row : Model.outline_row) ->
              View_base.outliner_node_icon current row) model_source row_source);
            if_ ~test:(Signal.map2 (fun current (row : Model.outline_row) ->
              View_base.outliner_node_icon current row = "" && row.row_list_number = None) model_source row_source)
            (icon ~name:(reactive (fun (row : Model.outline_row) ->
                `app (if row.is_collapsed && row.has_children then "outliner-bullet-closed" else "outliner-bullet")) row_source)
              ~width:24 ~height:24 ~foreground:"border"
              ~accessibility_identifier:
                ("outliner.bullet-glyph."
                 ^ View_base.outliner_row_uuid current_row)
              []);
          ];
        View_base.with_label_signal
          (Signal.map2 View_base.outliner_row_zoom_label model_source row_source)
          (button ~text:"" ~variant:`ghost ~width:24 ~height:24
             ~accessibility_identifier_signal:
               (Signal.map View_base.outliner_row_zoom_identifier
                  row_source)
             ~on_press
             []);
      ]
  else
    View_base.with_label_signal
      (Signal.map2 View_base.outliner_row_zoom_label model_source row_source)
      (icon_button ~icon:(`app "outliner-bullet") ~label:(View_base.outliner_row_zoom_label (Signal.sample model_source) current_row) ~size:`icon
         ~style_class:"body-line" ~variant:`ghost ~foreground:"border"
         ~width:24 ~height:24
         ~accessibility_identifier_signal:
           (Signal.map View_base.outliner_row_zoom_identifier row_source)
         ~on_press
         [])

let outliner_status_icon identifier test name row_source : t =
  if_ ~test:(Signal.map test row_source)
    (icon ~name ~size:`lg ~width:22 ~height:22
       ~foreground_signal:(Signal.map (fun (row : Model.outline_row) ->
         match row.row_status with Some status -> View_base.task_status_foreground status
         | None -> "foreground") row_source)
       ~accessibility_identifier:identifier [])

let outliner_status_control (context : Lui_ui.ui_context) model_source
    row_source send : t =
  let current_row = Signal.sample row_source in
  let status_menu =
    dropdown_menu [keyed_dropdown_menu_item
      ~source:(reactive View_base.model_task_statuses model_source)
      ~key:View_base.task_status_identifier ~cmp:compare
      ~mount:(fun status_source -> View_composer.outliner_task_status_row row_source status_source send)]
  in
  let native_status_menu =
    context_menu [keyed_context_menu_item
      ~source:(reactive View_base.model_task_statuses model_source)
      ~key:View_base.task_status_identifier ~cmp:compare
      ~mount:(fun status_source -> View_composer.outliner_task_status_context_row row_source status_source send)]
  in
  if Lui_ui.host context = KotlinHost then
    stack ~width:24 ~height:24
      [
        row ~width:24 ~height:24 ~main:`center ~cross:`center
          [
            stack ~width:22 ~height:22
              [
                outliner_status_icon
                  ("outliner.task-status-icon."
                   ^ View_base.outliner_row_uuid current_row)
                  View_base.outliner_task_status_backlog_
                  (`app "task-backlog") row_source;
                outliner_status_icon
                  ("outliner.task-status-icon."
                   ^ View_base.outliner_row_uuid current_row)
                  View_base.outliner_task_status_todo_ (`app "task-todo")
                  row_source;
                outliner_status_icon
                  ("outliner.task-status-icon."
                   ^ View_base.outliner_row_uuid current_row)
                  View_base.outliner_task_status_doing_ (`app "task-doing")
                  row_source;
                outliner_status_icon
                  ("outliner.task-status-icon."
                   ^ View_base.outliner_row_uuid current_row)
                  View_base.outliner_task_status_review_
                  (`app "task-review") row_source;
                outliner_status_icon
                  ("outliner.task-status-icon."
                   ^ View_base.outliner_row_uuid current_row)
                  View_base.outliner_task_status_done_ (`app "task-done")
                  row_source;
                outliner_status_icon
                  ("outliner.task-status-icon."
                   ^ View_base.outliner_row_uuid current_row)
                  View_base.outliner_task_status_canceled_
                  (`app "task-canceled") row_source;
              ];
          ];
        View_base.with_label_signal
          (Signal.map View_base.outliner_row_status_title row_source)
          (menu_trigger
             ~accessibility_identifier:"button.block-task-status"
             status_menu);
      ]
  else
    View_base.with_label_signal
      (Signal.map View_base.outliner_row_status_title row_source)
      (View_base.with_string_prop_signal InlineIconName
         (Signal.map View_base.outliner_task_status_icon row_source)
         (icon_button ~icon:(`app "task-todo") ~label:(View_base.outliner_row_status_title current_row) ~variant:`ghost ~style_class:"body-line"
            ~foreground:"secondary" ~size:`icon ~width:22 ~height:24
            ~accessibility_identifier:"button.block-task-status"
            [ native_status_menu ]))

let outliner_priority_control model_source row_source send : t =
  let row = Signal.sample row_source in
  let choose uuid = ignore (send (Model.SetOutlinerTaskPriority (row.Model.row_uuid, uuid))) in
  stack ~width:20 ~height:24 [
  View_base.with_string_prop_signal InlineIconName
    (Signal.map (fun (row : Model.outline_row) ->
       Option.fold ~none:"app:priority-low" ~some:View_base.task_priority_icon_name row.row_priority) row_source)
    (View_base.with_label_signal
       (Signal.map (fun (row : Model.outline_row) -> Option.fold ~none:"Priority" ~some:(fun (p : Model.task_status) -> p.title) row.row_priority) row_source)
       (menu_trigger ~foreground:"muted-foreground"
          ~accessibility_identifier:"button.block-task-priority"
          (dropdown_menu [
            keyed_dropdown_menu_item ~source:(Signal.map (fun (m : Model.logseq_model) -> m.task_priorities) model_source)
              ~key:View_base.task_status_identifier ~cmp:compare ~mount:(fun choice_source ->
                let choice = Signal.sample choice_source in
                dropdown_menu_item ~text_signal:(reactive (fun (p : Model.task_status) -> p.title) choice_source)
                  ~icon_signal:(Signal.map (fun p -> View_base.icon_of_wire_name (View_base.task_priority_icon_name p)) choice_source)
                  ~selected_signal:(Signal.map2 (fun (row : Model.outline_row) (p : Model.task_status) ->
                    Option.fold ~none:false ~some:(fun (selected : Model.task_status) -> selected.uuid = p.uuid) row.row_priority) row_source choice_source)
                  ~accessibility_identifier:("button.block-task-priority-option." ^ choice.uuid)
                  ~on_press:(fun _ -> choose (Signal.sample choice_source).uuid) []);
            dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Clear priority")
              ~accessibility_identifier:"button.block-task-priority-clear" ~on_press:(fun _ -> choose "") []
          ])))]

let code_language_control context model_source row_source send : t =
  let current_row = (Signal.sample row_source : Model.outline_row) in
  let trigger =
    menu_trigger ~style_class:"caption" ~foreground:"muted-foreground"
        ~text_signal:(Signal.map (fun row -> let value = code_language row in if value = "" then "Plain text" else value) row_source)
        ~label:(View_base.tr (Signal.sample model_source) "Code language")
        ~accessibility_identifier:("button.outliner.code-language." ^ current_row.row_uuid)
        (dropdown_menu (List.map (fun (value, label) ->
          dropdown_menu_item ~text:label ~accessibility_identifier:("button.outliner.code-language.option." ^ value)
            ~on_press:(fun _ ->
              let row = Signal.sample row_source in
              ignore (send (Model.SubmitNodeProperty (row.row_uuid, Yojson.Basic.to_string (`Assoc [
                "action", `String "setCodeLanguage"; "blockUuid", `String row.row_uuid; "value", `String value]))))) [])
          ["", "Plain text"; "bash", "Bash"; "c", "C"; "cpp", "C++"; "clojure", "Clojure";
           "css", "CSS"; "go", "Go"; "html", "HTML"; "java", "Java"; "javascript", "JavaScript";
           "json", "JSON"; "kotlin", "Kotlin"; "markdown", "Markdown"; "ocaml", "OCaml";
           "python", "Python"; "ruby", "Ruby"; "rust", "Rust"; "sql", "SQL"; "swift", "Swift";
           "typescript", "TypeScript"; "yaml", "YAML"; "calc", "Calculator"]) ) in
  let trigger = if Lui_ui.host context = KotlinHost then
      View_base.with_string_prop TextAlignment "start" trigger
    else trigger in
  if_ ~test:(Signal.map (fun (row : Model.outline_row) -> row.row_display_type = Some "code") row_source)
    (row ~main:`start ~padding_horizontal:12 ~padding_vertical:2
      ~accessibility_identifier:("outliner.code.language-header." ^ current_row.row_uuid)
      [box ~height:28 [trigger]])

let code_block_content model_source retained_source row_source send : t =
 custom @@ fun context parent ->
  let current_row = Signal.sample row_source in
  let source = Signal.map (fun retained -> if View_rows.retained_row_editing_ retained then
    View_rows.retained_row_editing_title retained else (View_rows.retained_row_value retained).Model.row_title) retained_source in
  let calculator = Signal.map (fun row -> code_language row = "calc") row_source in
  let input = column ~gap:0 ~cross:`stretch [
    if_ ~test:(reactive View_rows.retained_row_editing_ retained_source)
      (outliner_editor_view model_source (Signal.map View_base.outliner_row_uuid row_source)
        (Signal.map View_rows.retained_row_editing_title retained_source)
        (Signal.map View_rows.retained_row_editing_caret retained_source) send);
    if_ ~test:(Signal.map (fun retained -> not (View_rows.retained_row_editing_ retained)) retained_source)
      (list_item ~padding:0
        ~accessibility_identifier:("outliner.code.content." ^ current_row.row_uuid)
        ~on_press:(fun _ ->
          let uuid = (Signal.sample row_source).row_uuid in
          ignore (send (if View_base.outliner_selection_active_ (Signal.sample model_source)
            then Model.ToggleOutlinerSelection uuid else Model.BeginOutlinerEdit uuid)))
        ?on_long_press:(if Lui_ui.host context = SwiftUIHost then None else
          Some (fun _ -> ignore (send (Model.LongPressOutlinerBlock (Signal.sample row_source).row_uuid))))
        [reactive (fun calculator -> if calculator then
          text ~value:(reactive source) ~font_family:"monospace" ~font_size:"17" ~padding:12 [] else
          outliner_rich_block_view ~show_code_language:false model_source
            (Signal.map View_base.outliner_row_title row_source)
            (Signal.map (fun (row : Model.outline_row) -> row.markup_json) row_source)
            (Signal.map View_base.outliner_row_youtube_target row_source)
            (Signal.map (fun (row : Model.outline_row) -> row.is_asset) row_source) row_source
            (Signal.map View_base.outliner_row_asset_type row_source)
            (Signal.map View_base.outliner_row_local_path row_source) send) calculator]);
  ] in
  mount context ?parent (column ~gap:0 ~cross:`stretch ~corner_radius:8
    ~background_signal:(Signal.map (fun retained ->
      if View_rows.retained_row_selected_ retained then "#00000000" else "code-container") retained_source)
    ~accessibility_identifier:("outliner.code." ^ current_row.Model.row_uuid) [
      code_language_control context model_source row_source send;
      reactive (fun calculator -> if not calculator then input else
        let content = row ~gap:0 ~cross:`start
          ~accessibility_identifier:("outliner.calculator." ^ current_row.row_uuid) [box ~grow:1.0 [input];
          box ~min_width:64 ~padding:12 [
            text ~value:(reactive (fun source -> String.concat "\n" (Node_presentation.calculator_results source)) source)
              ~font_family:"monospace" ~font_size:"17" ~foreground:"muted-foreground"
              ~accessibility_identifier:("outliner.calculator.results." ^ current_row.row_uuid) []]] in
        if Lui_ui.host context <> KotlinHost then content else custom (fun context parent ->
          let node = Lui_ui.extension context "outliner-calculator-swipe" in
          attach context parent node;
          Lui_ui.extension_property_signal context node "block-id" (Signal.map View_base.outliner_row_id_wire_value row_source);
          Lui_ui.extension_property_signal context node "enabled"
            (Signal.map (fun row -> BoolValue (not (View_rows.retained_row_editing_ row))) retained_source);
          Lui_ui.on_event context node (fun input ->
            ignore (View_base.handle_outliner_block_content_event input model_source send));
          ignore (mount context ~parent:node content);
          node)) calculator;
    ])

let annotation_page_link row_source send =
  let reference = Signal.map (metadata_member "pdfAnnotation") row_source in
  let current_row = Signal.sample row_source in
  if_ ~test:(Signal.map (function `Assoc _ -> true | _ -> false) reference)
    (button ~text:"" ~variant:`ghost ~foreground:"link" ~height:44 ~padding_horizontal:4
      ~accessibility_identifier:("pdf.annotation-page." ^ current_row.Model.row_uuid)
      ~on_press:(fun _ -> ignore (send (Model.PdfWorkspaceEvent (Yojson.Basic.to_string (`Assoc
        ["action", `String "open-annotation"; "annotation", Signal.sample reference])))))
      [text ~value:(reactive (fun value ->
        let page = try Yojson.Basic.Util.(value |> member "page" |> to_int) with _ -> 0 in
        "📌 P" ^ string_of_int page) reference) ~style_class:"caption" []])

let outliner_row_main_content (context : Lui_ui.ui_context) model_source
    retained_row_source row_source send : t =
  let current_row = Signal.sample row_source in
  let block_id_source =
    Signal.map View_base.outliner_row_uuid row_source
  in
  let title_source = Signal.map View_base.outliner_row_title row_source in
  let markup_source =
    Signal.map (fun (r : Model.outline_row) -> r.markup_json) row_source
  in
  let youtube_target_source =
    Signal.map View_base.outliner_row_youtube_target row_source
  in
  let is_asset_source =
    Signal.map (fun (r : Model.outline_row) -> r.is_asset) row_source
  in
  let asset_type_source =
    Signal.map View_base.outliner_row_asset_type row_source
  in
  let local_path_source =
    Signal.map View_base.outliner_row_local_path row_source
  in
  let editing_title_source =
    Signal.map View_rows.retained_row_editing_title retained_row_source
  in
  let editing_caret_source =
    Signal.map View_rows.retained_row_editing_caret retained_row_source
  in
  let editing_source =
    Signal.map View_rows.retained_row_editing_ retained_row_source
  in
  let not_editing_source = Signal.map not editing_source in
  let has_children_source =
    Signal.map View_base.outliner_row_has_children row_source
  in
  let has_status_source =
    Signal.map View_base.outliner_row_has_status_ row_source
  in
  let has_tags_source =
    Signal.map View_base.outliner_row_has_tags_ row_source
  in
  let sync_failed_source =
    Signal.map View_base.outliner_row_sync_failed_ row_source
  in
  row ~gap:7 ~cross:`start ~grow:1.0
    [
      if_ ~test:has_status_source
        (column ~cross:`start
           [ outliner_status_control context model_source row_source send ]);
      if_ ~test:(reactive (fun (row : Model.outline_row) -> row.row_priority <> None) row_source)
        (outliner_priority_control model_source row_source send);
      annotation_page_link row_source send;
      column ~gap:2 ~grow:1.0 ~cross:`start
        ~accessibility_identifier:("outliner.title-and-tags." ^ current_row.row_uuid)
        [
          reactive (fun code -> if code then code_block_content model_source retained_row_source row_source send else
            column ~gap:0 ~cross:`stretch [
              if_ ~test:editing_source
                (outliner_editor_view model_source block_id_source editing_title_source editing_caret_source send);
              if_ ~test:not_editing_source
                (outliner_rich_block_view model_source title_source markup_source youtube_target_source is_asset_source
                  row_source asset_type_source local_path_source send)])
            (Signal.map (fun (row : Model.outline_row) -> row.row_display_type = Some "code") row_source);
          if_ ~test:has_tags_source
            (row ~gap:6
               [
                 keyed
                   ~source:
                     (Signal.map View_base.outliner_row_tags row_source)
                   ~key:View_base.outliner_tag_identifier ~cmp:compare
                   ~mount:(fun tag_source -> outliner_tag model_source current_row.row_uuid tag_source send);
               ]);
          if_ ~test:sync_failed_source
            (text
               ~accessibility_identifier:
                 ("outliner.sync-failed."
                  ^ View_base.outliner_row_uuid current_row)
               ~value:(View_base.tr (Signal.sample model_source) "Sync failed") []);
        ];
      if_ ~test:has_children_source
        (column ~cross:`start
           [ outliner_collapse_button context model_source row_source send ]);
    ]

let outliner_row_content context model_source retained_row_source
    row_source send : t =
  row ~gap:0 ~cross:`start ~padding_vertical:2
    [
      outliner_indent_view
        (Signal.map View_base.outliner_row_indent row_source);
      outliner_zoom_control context model_source row_source send;
      box ~width:2 [];
      outliner_row_main_content context model_source retained_row_source
        row_source send;
    ]

let native_outliner_row ~allow_drag ~trailing_inset model_source retained_source row_source send : t =
 custom @@ fun context parent ->
  let node = Lui_ui.extension context "outliner-block-row" in
  attach context parent node;
  let summary (page : Model.sidebar_page) = `Assoc ["uuid", `String page.uuid; "title", `String page.title] in
  let status (status : Model.task_status) = `Assoc ["uuid", `String status.uuid;
    "title", `String status.title; "icon", `String (View_base.task_status_icon_name status);
    "foreground", `String (View_base.task_status_foreground status)] in
  let payload (current : Model.logseq_model) (retained : View_rows.retained_row) =
    let row = View_rows.retained_row_value retained in
    Yojson.Basic.to_string (`Assoc [
      "uuid", `String row.row_uuid; "title", `String row.row_title;
      "scrollAnchorID", `String (Option.fold ~none:row.row_uuid
        ~some:(fun scope -> scope ^ "/" ^ row.row_uuid) retained.edit_scope);
      "embedSourceUuid", (match row.row_embed_source_uuid with Some uuid -> `String uuid | None -> `Null);
      "pdfAnnotation", metadata_member "pdfAnnotation" row;
      "listNumber", (match (if row.row_is_embed then None else row.row_list_number) with Some n -> `Int n | None -> `Null);
      "nodeIcon", (let icon = View_base.outliner_node_icon current row in
        if icon = "" then `Null else Yojson.Basic.from_string icon);
      "markup", (try Yojson.Basic.from_string row.markup_json with _ -> `List []);
      "depth", `Int row.depth; "hasChildren", `Bool row.has_children;
      "collapsed", `Bool row.is_collapsed; "isAsset", `Bool row.is_asset;
      "assetType", `String (View_base.outliner_row_asset_type row);
      "localPath", `String (View_base.outliner_row_local_path row);
      "youtubeURL", `String (View_base.outliner_row_youtube_target row);
      "completed", `Bool (View_base.outliner_row_completed_ row);
      "selected", `Bool retained.is_selected;
      "selectionMode", `Bool (View_base.outliner_selection_active_ current);
      "selectionMember", `Bool (View_base.row_selected_ current row);
      "isTask", metadata_member "isTask" row;
      "menuLabels", block_menu_labels current;
      "editing", `Bool (View_rows.retained_row_editing_ retained);
      "allowsDrag", `Bool allow_drag;
      "trailingInset", `Int trailing_inset;
      "hasCustomContent", `Bool (View_rows.retained_row_editing_ retained || row.row_display_type = Some "code");
      "canRemoveTags", `Bool (Model.node_can_set_tags current row.row_uuid);
      "removeTagTitle", `String (View_base.tr current "Remove tag");
      "openLabel", `String (View_base.outliner_row_zoom_label current row);
      "editLabel", `String (View_base.outliner_row_action_label current row);
      "collapseLabel", `String (View_base.outliner_row_collapse_label current row);
      "opensAsPage", `Bool row.opens_as_page;
      "journalBullet", `Bool false;
      "syncFailed", `Bool (View_base.outliner_row_sync_failed_ row);
      "priority", (match row.row_priority with None -> `Null | Some priority ->
        `Assoc ["uuid", `String priority.uuid; "title", `String priority.title;
          "icon", `String (View_base.task_priority_icon_name priority)]);
      "priorities", `List (List.map (fun (priority : Model.task_status) ->
        `Assoc ["uuid", `String priority.uuid; "title", `String priority.title;
          "icon", `String (View_base.task_priority_icon_name priority)]) current.task_priorities);
      "status", (match row.row_status with Some value -> status value | None -> `Null);
      "statuses", `List (List.map status current.task_statuses);
      "tags", `List (List.map summary row.tags)]) in
  Lui_ui.extension_property_signal context node "payload"
    (Signal.map2 (fun current retained -> StringValue (payload current retained)) model_source retained_source);
  ignore (mount context ~parent:node (reactive (fun code -> if code then code_block_content model_source retained_source row_source send else
    if_ ~test:(reactive View_rows.retained_row_editing_ retained_source)
      (box ~padding:0 [outliner_editor_view model_source (Signal.map View_base.outliner_row_uuid row_source)
        (Signal.map View_rows.retained_row_editing_title retained_source)
        (Signal.map View_rows.retained_row_editing_caret retained_source) send]))
    (Signal.map (fun (row : Model.outline_row) -> row.row_display_type = Some "code") row_source)));
  Lui_ui.on_event context node (function
    | ExtensionEvent (_, _, "remove-tag", values) ->
      (match String_map.find_opt "uuid" values with
       | Some (StringValue tag) -> ignore (send (remove_node_tag (Signal.sample model_source) (Signal.sample row_source).row_uuid tag))
       | _ -> ())
    | ExtensionEvent (_, _, "collapse", _) -> ignore (send (Model.ToggleOutlinerCollapsed (Signal.sample row_source).row_uuid))
    | ExtensionEvent (_, _, "long-press", _) -> ignore (send (Model.LongPressOutlinerBlock (Signal.sample row_source).row_uuid))
    | ExtensionEvent (_, _, "set-priority", values) ->
      (match String_map.find_opt "priority" values with
       | Some (StringValue priority) -> ignore (send (Model.SetOutlinerTaskPriority ((Signal.sample row_source).row_uuid, priority)))
       | _ -> ())
    | input -> handle_block_menu_event model_source row_source send input);
  node

let selected_row ~selected_signal content =
  View_base.with_bool_prop_signal Selected selected_signal content

let with_ios_trailing_padding padding content =
  custom (fun context parent ->
    let node = mount context ?parent content in
    if Lui_ui.host context = SwiftUIHost then Lui_ui.padding_right context node padding;
    node)

let outliner_row_body ?(allow_drag = true) ?(trailing_inset = 0) (context : Lui_ui.ui_context) model_source
    retained_row_source row_source send : t =
  let current_row = Signal.sample row_source in
  let search_open = (Signal.sample model_source : Model.logseq_model).search_open in
  if Lui_ui.host context = SwiftUIHost then
    selected_row ~selected:(reactive View_rows.retained_row_selected_ retained_row_source)
      (box ~padding:0 ~accessibility_identifier:(reactive View_base.outliner_row_identifier row_source)
        [native_outliner_row ~allow_drag ~trailing_inset model_source retained_row_source row_source send])
  else
  if
    View_base.outliner_row_list_item_press_enabled_
      (Lui_ui.host context) current_row
  then
    selected_row ~selected:(reactive View_rows.retained_row_selected_ retained_row_source)
      (box
         ~accessibility_identifier_signal:
           (Signal.map View_base.outliner_row_identifier row_source)
         ~padding:0 ~corner_radius:10
         [
           row ~gap:0 ~cross:`start ~padding_vertical:2
          [
            outliner_indent_view
              (Signal.map View_base.outliner_row_indent row_source);
            outliner_zoom_control context model_source row_source send;
            box ~width:2 [];
            selected_row ~selected:(reactive View_rows.retained_row_selected_ retained_row_source)
              (View_base.with_label_signal
                 (Signal.map2
                    (fun (current : Model.logseq_model)
                         (r : Model.outline_row) ->
                      View_base.outliner_row_action_label current r)
                    model_source row_source)
                 (list_item
                    ~accessibility_identifier_signal:
                      (Signal.map View_base.outliner_row_action_identifier
                         row_source)
                    ~padding:0 ~grow:1.0
                    ~on_press:(fun _ ->
                      ignore
                        (let current_row = Signal.sample row_source in
                         let asset_type = View_base.outliner_row_asset_type current_row |> String.lowercase_ascii in
                         let native_image = Lui_ui.host context = SwiftUIHost && current_row.is_asset
                           && (String.starts_with ~prefix:"image/" asset_type
                               || List.mem asset_type ["png"; "jpg"; "jpeg"; "gif"; "heic"; "webp"]) in
                         if native_image then true
                         else send
                           (if (current_row : Model.outline_row).is_asset then
                              Model.OpenOutlinerAsset
                                current_row.row_uuid
                            else if current_row.opens_as_page then
                              if search_open then
                                Model.RequestSearchNode
                                  current_row.row_uuid
                              else
                                Model.RequestAppNode current_row.row_uuid
                            else
                              Model.BeginOutlinerEdit
                                current_row.row_uuid)))
                    ~on_long_press:(fun _ ->
                      ignore
                        (send
                           (Model.LongPressOutlinerBlock
                              (Signal.sample row_source : Model.outline_row).row_uuid)))
                    [
                      outliner_row_main_content context model_source
                        retained_row_source row_source send;
                    ]));
           ];
         ])
  else
    selected_row ~selected:(reactive View_rows.retained_row_selected_ retained_row_source)
      (View_base.with_label_signal
         (Signal.map2
            (fun (current : Model.logseq_model) (r : Model.outline_row) ->
              View_base.outliner_row_action_label current r)
            model_source row_source)
         (box
            ~accessibility_identifier_signal:
              (Signal.map View_base.outliner_row_identifier row_source)
            ~padding:0 ~corner_radius:10
            [
              outliner_row_content context model_source
                retained_row_source row_source send;
            ]))

let outliner_text_leading context (row : Model.outline_row) =
  let status = row.row_status <> None and priority = row.row_priority <> None in
  let leading = if Lui_ui.host context = KotlinHost then
    26 + (if status then 31 else 0) + (if priority then 27 else 0)
  else (if status then 49 else if priority then 20 else 26) + (if priority then 25 else 0) in
  leading + row.depth * 22

let outliner_task_date_leading context (row : Model.outline_row) =
  match row.row_status with
  | None -> outliner_text_leading context row
  | Some _ ->
    (* Center the 16-point property glyph on the status control. *)
    let root = if Lui_ui.host context = KotlinHost then 30 else 24 in
    root + row.depth * 22

let outliner_continuation ?(is_body = false) row_source content : t = custom @@ fun context parent ->
  let node = Lui_ui.extension context "outliner-continuation" in
  attach context parent node;
  Lui_ui.extension_property_signal context node "guide-count"
    (Signal.map (fun (row : Model.outline_row) -> IntValue
      (row.depth + if row.has_children && not row.is_collapsed then 1 else 0)) row_source);
  Lui_ui.extension_property_signal context node "bullet-depth"
    (Signal.map (fun (row : Model.outline_row) -> IntValue
      (if is_body && row.has_children && not row.is_collapsed then row.depth else -1)) row_source);
  Lui_ui.extension_property_signal context node "identifier"
    (Signal.map (fun (row : Model.outline_row) -> StringValue ((if is_body then "body." else "metadata.") ^ row.row_uuid)) row_source);
  ignore (mount context ~parent:node content);
  node

let outliner_task_dates context model_source row_source send =
  let task_completed = Signal.map (fun (row : Model.outline_row) ->
    Option.exists (fun (status : Model.task_status) ->
      status.ident = Some "logseq.property/status.done"
      || status.ident = Some "logseq.property/status.canceled") row.row_status) row_source in
  View_base.with_int_prop_signal PaddingLeft
    (Signal.map (outliner_task_date_leading context) row_source)
    (box ~padding_horizontal:8 [View_property.view ~compact:true ~task_completed ~render_block:(fun _ _ -> box [])
      model_source (Signal.map (fun (row : Model.outline_row) -> row.row_task_dates_json) row_source) send])

let discussion_body model_source row_source body : t =
  let row = Signal.sample row_source in
  reactive (fun kind ->
    if kind = "thread" || kind = "comment" then
      column ~gap:4 ~padding_vertical:6 ~padding_horizontal:8 ~corner_radius:6
        ~background:"surface-container-low" ~border_width:1 ~border_color:"border"
        ~accessibility_identifier:("outliner.comment." ^ row.Model.row_uuid)
        [text ~value:(View_base.tr (Signal.sample model_source) (if kind = "thread" then "Comments" else "Comment"))
           ~style_class:"caption" ~foreground:"muted-foreground" []; body]
    else body)
    (Signal.map (fun row -> match metadata_member "discussionKind" row with `String value -> value | _ -> "") row_source)

let reaction_strip row_source : t =
  let reactions = Signal.map (fun row -> match metadata_member "reactions" row with
    | `List values -> values | _ -> []) row_source in
  if_ ~test:(Signal.map (fun values -> values <> []) reactions)
    (row ~gap:6 ~padding_horizontal:32 ~padding_vertical:4
      [keyed ~source:reactions ~key:(fun value -> Yojson.Basic.Util.member "emoji" value) ~cmp:compare
        ~mount:(fun source ->
          text ~value:(reactive (Signal.map (fun value ->
            let open Yojson.Basic.Util in
            let emoji = try value |> member "emoji" |> to_string with _ -> "" in
            let count = try value |> member "count" |> to_int with _ -> 0 in
            emoji ^ " " ^ string_of_int count) source))
            ~padding_horizontal:8 ~padding_vertical:4 ~corner_radius:8
            ~background:"muted" ~style_class:"caption" [])])

let decorate_row model_source row_source send body =
  column ~gap:0 [discussion_body model_source row_source body; reaction_strip row_source]

let with_embed_children model_source edit_scope row_source send render_row render_child : t =
  reactive (fun has_embed_children ->
    if not has_embed_children then render_row row_source send else
      custom @@ fun context parent ->
        let initial = Signal.sample row_source in
        let child_scope =
          if initial.Model.row_is_embed then
            Some (View_rows.embedded_edit_scope ~parent_scope:edit_scope ~page:initial.page_id
              ~row:initial.row_uuid ~mount_id:(Option.value ~default:0 parent))
          else edit_scope in
        let collapsed = Signal.state context.Lui_ui.ui_scheduler None in
        let row_source = Signal.map2 (fun (row : Model.outline_row) collapsed ->
          {row with has_children = true; is_collapsed = Option.value ~default:row.is_collapsed collapsed})
          row_source (Signal.value collapsed) in
        let row_send = function
          | Model.ToggleOutlinerCollapsed uuid when uuid = (Signal.sample row_source).row_uuid ->
            if (Signal.sample model_source : Model.logseq_model).outliner_editing <> None then
              ignore (send (Model.PerformOutlinerToolbarAction "hideKeyboard"));
            Signal.set collapsed (Some (not (Signal.sample row_source).is_collapsed));
            true
          | action -> send action in
        let children = Signal.map (fun (row : Model.outline_row) ->
          if row.is_collapsed then [] else List.map (fun (child : Model.outline_row) ->
            {child with depth = row.depth + 1}) row.row_embed_children) row_source in
        mount context ?parent (column ~gap:0 [
          render_row row_source row_send;
          keyed ~source:children ~key:View_base.outliner_row_uuid ~cmp:String.compare
            ~mount:(fun source -> render_child child_scope source send)
        ]))
    (Signal.map (fun (row : Model.outline_row) -> row.row_embed_children <> []) row_source)

let send_scoped_outliner_edit edit_scope send action =
  match edit_scope, action with
  | Some scope, Model.BeginOutlinerEdit uuid ->
    send (Model.BeginEmbeddedOutlinerEdit (scope, uuid, None))
  | Some scope, Model.BeginOutlinerEditAt (uuid, offset) ->
    send (Model.BeginEmbeddedOutlinerEdit (scope, uuid, Some offset))
  | _ -> send action

let rec render_result_block_in_scope context model_source edit_scope row_source send =
  with_embed_children model_source edit_scope row_source send (fun row_source send ->
    let send = send_scoped_outliner_edit edit_scope send in
    let retained = Signal.map2 (View_rows.make_retained_outline_row ?edit_scope) model_source row_source in
    column ~gap:0 [
      if_ ~test:(Signal.map View_base.outliner_row_structured_breadcrumb_ row_source)
        (scroll ~orientation:`horizontal ~height:28 [related_row_breadcrumbs model_source row_source send]);
      if_ ~test:(Signal.map View_base.outliner_row_fallback_breadcrumb_ row_source)
        (text ~value:(reactive (Signal.map View_base.outliner_row_breadcrumb row_source))
          ~style_class:"caption" ~foreground:"muted-foreground" []);
      (let body = decorate_row model_source row_source send (outliner_row_body context model_source retained row_source send) in
       if Lui_ui.host context = KotlinHost then outliner_continuation ~is_body:true row_source body else body);
      outliner_continuation row_source (outliner_task_dates context model_source row_source send)])
    (render_result_block_in_scope context model_source)

let render_result_block context model_source row_source send =
  custom (fun mount_context parent ->
    let uuid = (Signal.sample row_source : Model.outline_row).row_uuid in
    let scope = Some ("result." ^ string_of_int (Option.value ~default:0 parent) ^ "." ^ uuid) in
    mount mount_context ?parent (render_result_block_in_scope context model_source scope row_source send))

let node_properties ?(root = false) context model_source send =
  View_property.view ~render_block:(render_result_block_in_scope context model_source None) model_source
    (Signal.map (fun (model : Model.logseq_model) -> if root then model.properties_json else match View_base.active_node_projection model with
      | Some route -> route.node_properties_json | None -> model.properties_json) model_source) send

let page_title_spacer ?(has_properties = false) () =
  box ~height:(if has_properties then 24 else 20)
    ~accessibility_identifier:"spacer.page-title" []

let with_result_page ?(root = false) context model_source send fallback : t =
  reactive (fun full_page -> if not full_page then fallback else
    column ~grow:1.0 ~gap:0 ~cross:`stretch ~accessibility_identifier:"page.results" [
      box ~height:16 [];
      if_ ~test:(reactive View_base.active_node_has_breadcrumbs_ model_source)
        (node_breadcrumbs model_source send);
      if_ ~test:(reactive (if root then View_base.selected_page_content_title_visible_ else View_base.node_title_visible_) model_source)
        (column ~gap:0 [
          box ~padding_horizontal:16 [row ~gap:8 ~cross:`center [
            View_base.node_icon_view ~size:28 (Signal.map (fun current ->
              View_base.node_icon current (View_base.active_node_uuid current)) model_source);
            heading ~level:`h3 ~style_class:"scroll-section-title"
              ~value:(reactive View_base.active_node_title model_source)
              ~accessibility_identifier:(if root then "title.selected-page" else "title.node") []]];
          page_title_spacer ()]);
      node_properties ~root context model_source send;
      box ~grow:1.0 ~padding_horizontal:16 ~padding_vertical:8 [
        View_query.collection ~fill_height:true ~render_block:(render_result_block context model_source)
          model_source (Signal.map View_base.active_node_result_views model_source) send];
    ])
    (Signal.map (fun current ->
      (View_base.current_content_is_tag_ current || View_base.current_content_is_property_ current)
      && View_base.page_content_ready_ current && View_base.active_node_result_views current <> "") model_source)

let outliner_row ?(trailing_inset = 0) context model_source retained_row_source row_source send : t =
  with_embed_children model_source None row_source send (fun row_source send ->
  let retained_row_source = Signal.map2 (fun (retained : View_rows.retained_row) value ->
    {retained with value}) retained_row_source row_source in
  let body = outliner_row_body ~trailing_inset context model_source retained_row_source row_source send in
  let body = decorate_row model_source row_source send body in
  let body = if Lui_ui.host context = KotlinHost then outliner_continuation ~is_body:true row_source body else body in
  let render_block = render_result_block context model_source in
  let bullet_inset = if Lui_ui.host context = KotlinHost then 12 else 20 in
  reactive (fun (has_query, has_properties, has_dates) ->
    if not has_query && not has_properties && not has_dates then body else
    let dates = if has_properties || not has_dates then [] else [outliner_task_dates context model_source row_source send] in
    let properties = if not has_properties then [] else [
      View_base.with_int_prop_signal PaddingLeft
        (Signal.map (fun row -> max 0 (outliner_text_leading context row - 16)) row_source)
        (box [node_properties context model_source send])] in
    let query = if not has_query then [] else [
      View_base.with_int_prop_signal PaddingLeft
        (Signal.map (fun (row : Model.outline_row) -> bullet_inset + row.depth * 22) row_source)
        (box ~padding_horizontal:8
          ~accessibility_identifier_signal:(Signal.map (fun (row : Model.outline_row) -> "query.inset." ^ row.row_uuid) row_source)
          [View_query.view ~render_block model_source row_source send])] in
    column ~gap:0 [body;
      outliner_continuation row_source
        (with_ios_trailing_padding trailing_inset (column ~gap:0 (dates @ properties @ query)))])
    (Signal.map2 (fun (model : Model.logseq_model) (row : Model.outline_row) ->
      row.query_json <> "", (match View_base.active_node_projection model with
      | Some route -> route.node_uuid = row.row_uuid && route.node_uuid <> route.node_page_uuid
        && View_property.has_properties route.node_properties_json
      | None -> false), View_property.has_properties row.row_task_dates_json) model_source row_source))
    (render_result_block_in_scope context model_source)

let page_heading_text ?accessibility_identifier parts =
  let suffix = Signal.map snd parts in
  [heading ~level:`h3 ~style_class:"scroll-section-title" ~value:(reactive fst parts)
     ?accessibility_identifier [];
   if_ ~test:(Signal.map Option.is_some suffix)
     (text ~value:(reactive (Option.value ~default:"") suffix) ~style_class:"subheadline single-line"
        ~foreground:"muted-foreground" ~accessibility_identifier:"journal.weekday" [])]

let journal_heading model_source row_source parts send children : t =
 custom @@ fun context parent ->
  let node =
    mount context ?parent (View_base.with_label_signal
       (Signal.map2 View_base.journal_heading_label model_source parts)
       (box ~padding:0
          ~accessibility_identifier_signal:
            (Signal.map2 View_base.outliner_journal_button_identifier
               model_source row_source)
          children))
  in
  Lui_ui.bool_property context node PressEnabled true;
  register_press context node (fun _ ->
    ignore (send (Model.RequestAppNode
      (View_base.outliner_journal_page_id
         (Signal.sample model_source) (Signal.sample row_source)))));
  node

let outliner_entry context model_source retained_row_source row_source
    send : t =
  let inset = 8 in
  let parts = Signal.map2 View_base.outliner_journal_title_parts model_source row_source in
  (* On iOS the disclosure button includes the trailing gutter. *)
  with_ios_trailing_padding 0 (column ~padding_horizontal:inset
    ~accessibility_identifier_signal:(Signal.map (fun (row : Model.outline_row) -> "outliner.entry." ^ row.row_uuid) row_source)
    [
      if_
        ~test:
          (Signal.map2
             (fun (current : Model.logseq_model) (r : Model.outline_row) ->
               View_base.outliner_journal_divider_visible_ current r)
             model_source row_source)
        (with_ios_trailing_padding inset (column ~gap:0
           [ box ~height:26 [];
             separator ~accessibility_identifier:"journal.divider" [] ]));
      if_
        ~test:
          (Signal.map2
             (fun (current : Model.logseq_model) (r : Model.outline_row) ->
               View_base.outliner_journal_heading_visible_ current r)
             model_source row_source)
        (with_ios_trailing_padding inset (journal_heading model_source row_source parts send
           [
             (* Align the Android title edge with the center of its 24dp bullet slot. *)
             box
               ~padding_horizontal:
                 (if Lui_ui.host context = KotlinHost then 12 else 8)
               [
                 View_base.with_int_prop_signal HeightValue
                   (Signal.map2
                      (fun (current : Model.logseq_model) (r : Model.outline_row) ->
                        if View_base.outliner_journal_divider_visible_ current r
                        then 26 else 0)
                      model_source row_source)
                   (box []);
                 row ~gap:8 ~cross:`center (
                 View_base.node_icon_view ~size:28 (Signal.map2 (fun current row ->
                   View_base.node_icon current (View_base.outliner_journal_page_id current row)) model_source row_source)
                 :: page_heading_text parts);
                 page_title_spacer ();
               ];
           ]));
      outliner_row ~trailing_inset:inset context model_source retained_row_source row_source
        send;
    ])


let toolbar_button model_source icon label identifier action send : t =
  icon_button ~icon ~variant:`ghost ~size:`icon ~width:48 ~height:48
    ~label:(View_base.tr (Signal.sample model_source) label)
    ~accessibility_identifier:identifier
    ~on_press:(fun _ ->
      ignore (send (Model.PerformOutlinerToolbarAction action)))
    []

type selection_tag_snapshot = {
  selection_tag_id : string;
  selection_tag_graph_id : string;
  selection_tag_block_uuids : string list;
  selection_tag_revision : int;
  selection_tag_location :
    Model.primary_destination * string option * bool * Model.navigation_route list
    * Model.navigation_route list * string list;
}

let outliner_selection_toolbar (context : Lui_ui.ui_context) model_source send : t =
  let task_selection = Signal.map Model.outliner_task_selection_ model_source in
  let date_buttons button =
    List.map (fun (field, label, icon) ->
      let id = "button.outliner.selection." ^ field in
      let on_press () = ignore (send (Model.OpenSelectedTaskDate field)) in
      if_toolbar ~test:task_selection
        (button (`app icon) label id on_press)) task_date_fields in
  let location (current : Model.logseq_model) =
    current.destination,
    Option.map (fun (page : Model.sidebar_page) -> page.uuid) current.selected_page,
    current.search_open,
    current.app_navigation_path,
    current.search_navigation_path,
    List.map (fun (route : Model.node_projection) -> route.node_uuid) current.node_routes in
  let snapshot_is_current (current : Model.logseq_model) snapshot =
    current.selected_graph_id = Some snapshot.selection_tag_graph_id
    && current.outliner_selected_block_ids = snapshot.selection_tag_block_uuids
    && current.outliner_selection_revision = snapshot.selection_tag_revision
    && location current = snapshot.selection_tag_location in
  let picker = Signal.state context.ui_scheduler None in
  let finished = ref None in
  let send_property_action action = ignore (send action); true in
  let picker_id snapshot = snapshot.selection_tag_id in
  let open_picker () =
    let current : Model.logseq_model = Signal.sample model_source in
    match current.selected_graph_id, current.outliner_selected_block_ids with
    | Some graph_id, (_ :: _ as block_uuids) ->
      let id = "selection.tags." ^ String.concat "." block_uuids ^ "."
        ^ string_of_int current.next_effect_id in
      Signal.set picker (Some {
        selection_tag_id = id;
        selection_tag_graph_id = graph_id;
        selection_tag_block_uuids = block_uuids;
        selection_tag_revision = current.outliner_selection_revision;
        selection_tag_location = location current;
      })
    | _ -> () in
  ignore (Signal.own context.ui_scope (Signal.observe model_source (fun current ->
    match Signal.sample (Signal.value picker) with
    | Some snapshot when not (snapshot_is_current current snapshot) ->
      Signal.set picker None
    | Some snapshot ->
      (match List.find_opt (fun (key, _, _) -> key = picker_id snapshot) current.result_view_feedback with
       | Some (_, revision, error) when !finished <> Some revision ->
         finished := Some revision;
         if error = None then Signal.set picker None
       | _ -> ())
    | None -> ())));
  let tag_label = View_base.tr (Signal.sample model_source) "Tag" in
  let render_tag_picker snapshot =
    let current : Model.logseq_model = Signal.sample model_source in
    match snapshot with
      | Some snapshot when snapshot_is_current current snapshot ->
        let owner = List.hd snapshot.selection_tag_block_uuids in
        let property = `Assoc [
          "attr", `String "block/tags";
          "title", `String "Add tags";
          "kind", `String "class";
          "many", `Bool true;
          "ref", `Bool true;
          "editable", `Bool true;
          "canCreate", `Bool true;
          "closed", `Bool false;
          "filterValues", `List [];
          "valuesDeferred", `Bool true;
          "raw", `Assoc ["type", `String "set"; "value", `List []];
        ] in
        View_query.property_editor ~owner ~send:send_property_action ~id:(picker_id snapshot) ~column:property
          ~submit:(fun fields ->
            let current = Signal.sample model_source in
            if snapshot_is_current current snapshot then
              ignore (send (Model.SubmitNodeProperty (picker_id snapshot,
                Yojson.Basic.to_string (`Assoc ([
                  "action", `String "addTags";
                  "graphId", `String snapshot.selection_tag_graph_id;
                  "blockUuids", `List (List.map (fun uuid -> `String uuid)
                    snapshot.selection_tag_block_uuids)] @ fields)))))
            else Signal.set picker None)
          model_source property (fun () -> Signal.set picker None)
      | _ -> box [] in
  let selection_toolbar =
    let android = Lui_ui.host context = KotlinHost in
    let hit_size = if android then 48 else 44 in
      reactive ~equal:(fun before after ->
        before.Model.task_statuses = after.Model.task_statuses && before.language = after.language) (fun current ->
      let quick_button ?on_press icon label identifier action : toolbar_el =
          let label = View_base.tr current label in
          Lui_elements.toolbar_icon_button ~width:hit_size ~icon ~variant:`ghost ~height:hit_size ~size:`icon
          ~foreground:"foreground" ~label
          ~accessibility_identifier:identifier
          ~on_press:(Option.value on_press ~default:(fun () ->
            ignore (send (Model.PerformOutlinerToolbarAction action))))
          []
      in
      let tag_button =
        quick_button ~on_press:open_picker (`app "toolbar-tag") tag_label
          "button.outliner.selection.tag" ""
      in
      let status_menu = toolbar_menu ~icon:(`app "toolbar-task") ~label:(View_base.tr current "Status")
        ~accessibility_identifier:"button.outliner.selection.status"
        (List.map (fun (status : Model.task_status) ->
           dropdown_menu_item ~text:status.title ~icon:(View_base.icon_of_wire_name (View_base.task_status_icon_name status))
             ~foreground:(View_base.task_status_foreground status)
             ~accessibility_identifier:("button.outliner.selection.status." ^ status.uuid)
             ~on_press:(fun () -> ignore (send (Model.SetSelectedOutlinerTaskStatus status.uuid))) [])
           current.task_statuses) in
      let menu_item ?(variant = `ghost) icon label action =
        dropdown_menu_item ~icon:(`app icon) ~variant ~text:(View_base.tr current label)
          ~accessibility_identifier:("button.outliner.selection.menu." ^ action)
          ~on_press:(fun () -> ignore (send (Model.PerformOutlinerToolbarAction action))) [] in
      let more = toolbar_menu ~icon:(`app "more-horiz") ~label:(View_base.tr current "More actions")
        ~accessibility_identifier:"button.outliner.selection.more" [
          menu_item "toolbar-copy" "Copy" "copy";
          menu_item "toolbar-cut" "Cut" "cut";
          menu_item "toolbar-copy-reference" "Copy reference" "copyReference";
          menu_item "toolbar-copy-url" "Copy URL" "copyURL";
          menu_item ~variant:`destructive "toolbar-delete" "Delete" "delete";
        ] in
      let actions = [
        status_menu;
        quick_button (`app "toolbar-outdent") "Outdent" "button.outliner.selection.outdent" "outdent";
        quick_button (`app "toolbar-indent") "Indent" "button.outliner.selection.indent" "indent";
        quick_button (`app "toolbar-move-up") "Move up" "button.outliner.selection.moveUp" "moveUp";
        quick_button (`app "toolbar-move-down") "Move down" "button.outliner.selection.moveDown" "moveDown";
      ] @ date_buttons (fun icon label id on_press ->
        quick_button ~on_press icon label id "") @ [
        quick_button (`app "toolbar-copy") "Copy" "button.outliner.selection.copy" "copy";
        tag_button;
      ] in
      let label = View_base.tr current "Outliner selection" in
      if android then
        row ~grow:1.0 ~cross:`center ~gap:8
          ~accessibility_identifier:"surface.outliner.selection-toolbar" [
            box ~grow:1.0 [
              toolbar ~orientation:`horizontal ~label
                ~accessibility_identifier:"toolbar.outliner.selection" ~toolbar_gap:2 actions;
            ];
            toolbar ~orientation:`horizontal ~label:(View_base.tr current "More actions") [more];
          ]
      else
        custom (fun context parent ->
          let node = Lui_ui.extension context "native-outliner-selection-toolbar" in
          attach context parent node;
          Lui_ui.extension_property context node "status-label" (StringValue (View_base.tr current "Status"));
          Lui_ui.extension_property context node "statuses" (StringValue (Yojson.Basic.to_string (`List
            (List.map (fun (status : Model.task_status) -> `Assoc [
              "uuid", `String status.uuid; "title", `String status.title;
              "icon", `String (View_base.task_status_icon_name status);
              "foreground", `String (View_base.task_status_foreground status);
            ]) current.task_statuses))));
          Lui_ui.on_event context node (function
            | ExtensionEvent (_, _, "select-status", values) ->
              (match String_map.find_opt "value" values with
               | Some (StringValue uuid) -> ignore (send (Model.SetSelectedOutlinerTaskStatus uuid))
               | _ -> ())
            | _ -> ());
          ignore (mount context ~parent:node
            (toolbar ~orientation:`horizontal ~label ~accessibility_identifier:"toolbar.outliner.selection"
              ~toolbar_gap:2 ~placement:`bottom (actions @ [more])));
          node))
      model_source
  in
  stack [
    selection_toolbar;
    reactive render_tag_picker (Signal.value picker);
  ]

let outliner_autocomplete_row (context : Lui_ui.ui_context)
    ~node_labels candidate_source send : t =
  let candidate = Signal.sample candidate_source in
  let choose () = ignore (send (Model.ChooseOutlinerAutocomplete
    (Signal.sample candidate_source : Model.outliner_autocomplete_candidate).candidate_value)) in
  let reference_label = custom @@ fun context parent ->
    let node = Lui_ui.extension context "outliner-block-content" in
    attach context parent node;
    List.iter (fun (key, value) -> Lui_ui.extension_property context node key (StringValue value))
      ["youtube-target-url", ""; "asset-type", ""; "local-path", ""];
    List.iter (fun key -> Lui_ui.extension_property context node key (BoolValue false)) ["is-asset"; "is-completed"];
    Lui_ui.extension_property_signal context node "block-id"
      (Signal.map (fun (c : Model.outliner_autocomplete_candidate) -> StringValue c.candidate_value) candidate_source);
    Lui_ui.extension_property_signal context node "title"
      (Signal.map (fun (c : Model.outliner_autocomplete_candidate) -> StringValue c.candidate_label) candidate_source);
    Lui_ui.extension_property_signal context node "markup-json"
      (Signal.map (fun (c : Model.outliner_autocomplete_candidate) -> StringValue c.candidate_markup_json) candidate_source);
    Lui_ui.on_event context node (function
      | ExtensionEvent (_, _, ("open-node" | "edit"), _) -> choose ()
      | _ -> ());
    node in
  let reference_label =
    if Lui_ui.host context = KotlinHost then
      row ~cross:`center [reference_label]
    else reference_label in
  column ~gap:0 ~grow:0.0 ~cross:`stretch [
  reactive (fun (candidate : Model.outliner_autocomplete_candidate) -> match candidate.candidate_group with
    | None -> box []
    | Some group -> text ~value:group ~font_size:"12" ~foreground:"muted-foreground"
        ~padding_horizontal:10 ~padding_vertical:5
        ~accessibility_identifier:("outliner.autocomplete.group." ^ group) []) candidate_source;
  row ~height:44 ~grow:0.0 ~cross:`center [View_base.with_label_signal
    (Signal.map View_base.outliner_autocomplete_label candidate_source)
    (View_base.with_string_prop_signal AccessibilityIdentifier
      (Signal.map View_base.outliner_autocomplete_identifier candidate_source)
    (button ~text:""
       ?text_signal:(if node_labels then None else Some
         (Signal.map View_base.outliner_autocomplete_label candidate_source))
       ~variant:`ghost
       ~grow:1.0
       ~height:44 ~padding_horizontal:10
       ~background:"autocomplete-row-background" ~foreground:"foreground"
       ~corner_radius:8 ~text_alignment:`start
       ~accessibility_identifier:
         (View_base.outliner_autocomplete_identifier candidate)
       ~on_press:(fun _ -> choose ())
       (if node_labels then [reference_label] else [])))]]

let outliner_autocomplete_bar (context : Lui_ui.ui_context) model_source send : t =
  let kind = function
    | Model.CommandAutocomplete -> "command" | NodeAutocomplete -> "node" | TagAutocomplete -> "tag"
    | PropertyAutocomplete -> "property" | PickerAutocomplete kind -> kind in
  let title = function "command" -> "Commands" | "node" -> "Pages" | "tag" -> "Tags"
    | "embed" -> "Embed a node" | "template" -> "Templates" | "link" -> "Link"
    | "image" -> "Image link" | "date" -> "Date picker" | "deadline" -> "Deadline"
    | "scheduled" -> "Scheduled" | "youtube" -> "YouTube timestamp" | _ -> "Properties" in
  let emit event value = ignore (send (Model.EditorCompletion (event, value))) in
  let dismiss () = emit "dismissAutocomplete" "" in
  let source = Signal.map (fun (current : Model.logseq_model) ->
    match current.outliner_autocomplete with Some request -> [kind request.autocomplete_kind] | None -> []) model_source in
  keyed ~source ~key:Fun.id ~cmp:String.compare ~mount:(fun source ->
    let kind = Signal.sample source in
    let form = List.mem kind ["link"; "image"; "date"; "deadline"; "scheduled"; "youtube"] in
    if form then (custom @@ fun context parent ->
      let temporal = List.mem kind ["date"; "deadline"; "scheduled"] in
      let date_kind = if kind = "date" then "date" else "datetime" in
      let value = Signal.state context.Lui_ui.ui_scheduler (if temporal then View_query.temporal_default date_kind else "") in
      let label = Signal.state context.ui_scheduler "" in
      let input state = fun value -> Signal.set state value  in
      let confirm _ =
        let value = Signal.sample (Signal.value value) in
        let value = if kind = "link" || kind = "image" then Yojson.Basic.to_string (`Assoc
          ["url", `String value; "label", `String (Signal.sample (Signal.value label))]) else value in
        emit "submitAutocomplete" value in
      let cancel = button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
        ~accessibility_identifier:"button.outliner.autocomplete.dismiss" ~on_press:(fun _ -> dismiss ()) [] in
      let toolbar_cancel = Lui_elements.toolbar_button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action" ~foreground:"foreground"
        ~accessibility_identifier:"button.outliner.autocomplete.dismiss" ~on_press:(fun _ -> dismiss ()) [] in
      let done_ = button ~text:(View_base.tr (Signal.sample model_source) "Insert") ~variant:`ghost ~style_class:"confirmation-action"
        ~accessibility_identifier:"button.outliner.autocomplete.submit" ~on_press:confirm [] in
      let toolbar_done_ = Lui_elements.toolbar_button ~text:(View_base.tr (Signal.sample model_source) "Insert") ~variant:`ghost ~style_class:"confirmation-action" ~foreground:"foreground"
        ~accessibility_identifier:"button.outliner.autocomplete.submit" ~on_press:confirm [] in
      mount context ?parent (View_base.sheet ~model_source ~title:(title kind) ~detents:(if temporal then "large" else "medium,large") ~style_class:"navigation-list navigation-inline-title"
        ~accessibility_identifier:"sheet.outliner.autocomplete" ~on_dismiss:(fun _ -> dismiss ()) [
        list ~grow:1.0 ~style:`inset_grouped [list_section (
          if temporal then [list_section_item ~padding_horizontal:0 ~padding_vertical:0 [
            View_query.temporal_picker ~on_submit:confirm model_source date_kind "editor-command" (Signal.value value) (Signal.set value)]]
          else [list_section_item [text_field ~text_signal:(Signal.value value) ~autofocus:true
            ~placeholder:(if kind = "youtube" then "1:32" else "https://example.com")
            ~label:(if kind = "youtube" then "Timestamp" else "URL")
            ~accessibility_identifier:"field.outliner.autocomplete.value" ~on_input:(input value) []]]
          @ (if kind = "link" || kind = "image" then [list_section_item [text_field ~text_signal:(Signal.value label)
            ~placeholder:(View_base.tr (Signal.sample model_source) "Label (optional)") ~label:(View_base.tr (Signal.sample model_source) "Label") ~accessibility_identifier:"field.outliner.autocomplete.label"
            ~on_input:(input label) []]] else []))];
        (if Lui_ui.host context = KotlinHost then row ~main:`space_between ~padding:12 [cancel; done_]
         else toolbar ~label:(View_base.tr (Signal.sample model_source) "Insert content") ~style_class:"navigation-actions" [toolbar_cancel; toolbar_done_]);
      ]))
    else
      column ~gap:2 ~padding:8 ~height:220 ~max_height:220 ~cross:`stretch ~main:`start ~accessibility_identifier:"toolbar.outliner.autocomplete" [
        row ~grow:0.0 ~main:`space_between ~cross:`center [
          text ~value:(title kind) ~font_size:"13" ~foreground:"muted-foreground" ~padding_horizontal:8 [];
          button ~text:(View_base.tr (Signal.sample model_source) "Close") ~variant:`ghost ~height:36 ~label:(View_base.tr (Signal.sample model_source) "Close suggestions")
            ~accessibility_identifier:"button.outliner.autocomplete.dismiss" ~on_press:(fun _ -> dismiss ()) []];
        (if kind = "embed" || kind = "template" then
          search_field ~placeholder:(View_base.tr (Signal.sample model_source) "Search") ~label:(title kind) ~autofocus:true
            ~text_signal:(Signal.map (fun (current : Model.logseq_model) ->
              Option.fold ~none:"" ~some:(fun request -> request.Model.autocomplete_query) current.outliner_autocomplete) model_source)
            ~accessibility_identifier:"field.outliner.autocomplete.search"
            ~on_input:(fun value -> emit "searchAutocomplete" value ) []
         else box []);
        scroll ~height:(if kind = "embed" || kind = "template" then 128 else 164) ~max_height:164 ~style_class:"outliner-autocomplete" [
          column ~gap:2 ~cross:`stretch [
            keyed ~source:(Signal.map View_base.model_outliner_autocomplete_candidates model_source)
              ~key:(fun (c : Model.outliner_autocomplete_candidate) -> c.candidate_value) ~cmp:String.compare
              ~mount:(fun source -> outliner_autocomplete_row context
                ~node_labels:(List.mem kind ["node"; "tag"; "embed"; "template"]) source send);
            if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> current.outliner_autocomplete_candidates = []) model_source)
              (text ~value:(View_base.tr (Signal.sample model_source) "No results") ~foreground:"muted-foreground" ~padding:16 []);
          ]];
      ])

let outliner_editor_toolbar (context : Lui_ui.ui_context) model_source send
    : t =
  let model_source = Signal.map (fun (model : Model.logseq_model) ->
    match View_rows.journal_task_editing_row model with
    | Some row -> {model with outliner_rows = row :: model.outliner_rows}
    | None -> model) model_source in
  let editing_task (current : Model.logseq_model) =
    Option.exists (fun (editing : Model.outliner_editing) ->
      match editing.editing_is_task with
      | Some is_task -> is_task
      | None -> List.exists (fun (row : Model.outline_row) ->
          row.row_uuid = editing.editing_uuid && metadata_member "isTask" row = `Bool true)
          current.outliner_rows) current.outliner_editing in
  let show_task_dates = Signal.map editing_task model_source in
  let open_date field () =
    let current : Model.logseq_model = Signal.sample model_source in
    if editing_task current then
      Option.iter (fun editing ->
        ignore (send (Model.OpenBlockTaskDate (editing.Model.editing_uuid, field)))) current.outliner_editing in
  let date_label name = View_base.tr (Signal.sample model_source) name in
  let android_date field name image =
    icon_button ~icon:(`app image) ~variant:`ghost ~size:`icon ~width:48 ~height:48
      ~label:(date_label name) ~accessibility_identifier:("button.outliner.editor." ^ field)
      ~on_press:(open_date field) [] in
  let ios_date field name image =
    Lui_elements.toolbar_icon_button ~icon:(`app image) ~variant:`ghost ~width:38 ~height:42
      ~label:(date_label name) ~accessibility_identifier:("button.outliner.editor." ^ field)
      ~on_press:(open_date field) [] in
  let new_block =
    if_ ~test:(Signal.map (fun (current : Model.logseq_model) ->
      Option.fold ~none:false ~some:(fun editing ->
        List.exists (fun (row : Model.outline_row) -> row.row_uuid = editing.Model.editing_uuid
          && row.row_display_type = Some "code") current.outliner_rows) current.outliner_editing) model_source)
      (icon_button ~icon:(`app "add") ~variant:`ghost
        ?size:(if Lui_ui.host context = KotlinHost then Some `icon else None)
        ~width:(if Lui_ui.host context = KotlinHost then 48 else 38)
        ~height:(if Lui_ui.host context = KotlinHost then 48 else 42)
        ~label:(View_base.tr (Signal.sample model_source) "Create new block")
        ~accessibility_identifier:"button.outliner.editor.newBlock"
        ~on_press:(fun _ -> ignore (send (Model.PerformOutlinerToolbarAction "newBlock"))) []) in
  let editing_non_code_block (current : Model.logseq_model) =
    Option.fold ~none:false ~some:(fun editing ->
      not (List.exists (fun (row : Model.outline_row) -> row.row_uuid = editing.Model.editing_uuid
        && row.row_display_type = Some "code") current.outliner_rows)) current.outliner_editing in
  let line_break_label = View_base.tr (Signal.sample model_source) "Line break" in
  let line_break =
    if_ ~test:(reactive editing_non_code_block model_source)
      (toolbar_button model_source (`app "toolbar-line-break") line_break_label
         "button.outliner.editor.lineBreak" "lineBreak" send) in
  let toolbar_line_break =
    if_toolbar ~test:(reactive editing_non_code_block model_source)
      (Lui_elements.toolbar_icon_button ~icon:(`app "toolbar-line-break") ~variant:`ghost
         ~width:38 ~height:42 ~label:line_break_label
         ~accessibility_identifier:"button.outliner.editor.lineBreak"
         ~on_press:(fun () -> ignore (send (Model.PerformOutlinerToolbarAction "lineBreak"))) []) in
  let toolbar_new_block =
    if_toolbar ~test:(reactive (fun (current : Model.logseq_model) ->
      Option.fold ~none:false ~some:(fun editing ->
        List.exists (fun (row : Model.outline_row) -> row.row_uuid = editing.Model.editing_uuid
          && row.row_display_type = Some "code") current.outliner_rows) current.outliner_editing) model_source)
      (Lui_elements.toolbar_icon_button ~icon:(`app "add") ~variant:`ghost ~width:38 ~height:42
        ~label:(View_base.tr (Signal.sample model_source) "Create new block")
        ~accessibility_identifier:"button.outliner.editor.newBlock"
        ~on_press:(fun () -> ignore (send (Model.PerformOutlinerToolbarAction "newBlock"))) []) in
  if Lui_ui.host context = KotlinHost then
    let task_status (current : Model.logseq_model) =
      match current.outliner_editing with
      | Some editing ->
        (match Model.row_index current.outliner_rows editing.editing_uuid with
         | Some index -> (List.nth current.outliner_rows index).row_status
         | None -> None)
      | None -> None
    in
    let task_icon current =
      match task_status current with
      | Some status ->
        View_base.icon_of_wire_name (View_base.task_status_icon_name status)
      | None -> `app "toolbar-task"
    in
    let task_foreground current =
      match task_status current with
      | Some status -> View_base.task_status_foreground status
      | None -> "foreground"
    in
    box
      ~accessibility_identifier:"surface.outliner.editor-toolbar"
      [
        row ~gap:0 ~cross:`center ~background:"surface-container-low"
          ~accessibility_identifier:"toolbar.outliner.editor"
          [ scroll ~orientation:`horizontal ~height:48 ~grow:1.0
              [ row ~gap:4 ~cross:`center
          [
            View_base.with_label_signal
              (Signal.map View_base.outliner_editor_task_label model_source)
              (icon_button ~label:(View_base.tr (Signal.sample model_source) "Task status") ~icon:(reactive task_icon model_source)
                 ~foreground:(reactive task_foreground model_source)
                 ~variant:`ghost
                 ~size:`icon ~width:48 ~height:48
                 ~accessibility_identifier:"button.outliner.editor.task"
                 ~on_press:(fun _ ->
                   ignore
                     (send
                        (Model.PerformOutlinerToolbarAction "task")))
                 []);
            if_ ~test:show_task_dates (android_date "scheduled" "Scheduled" "calendar");
            if_ ~test:show_task_dates (android_date "deadline" "Deadline" "deadline");
            toolbar_button model_source (`app "toolbar-outdent") "Outdent"
              "button.outliner.editor.outdent" "outdent" send;
            toolbar_button model_source (`app "toolbar-indent") "Indent"
              "button.outliner.editor.indent" "indent" send;
            toolbar_button model_source (`app "toolbar-move-up") "Move up"
              "button.outliner.editor.moveUp" "moveUp" send;
            toolbar_button model_source (`app "toolbar-move-down") "Move down"
              "button.outliner.editor.moveDown" "moveDown" send;
            new_block;
            line_break;
            toolbar_button model_source (`app "toolbar-tag") "Tag"
              "button.outliner.editor.tag" "tag" send;
            toolbar_button model_source (`app "toolbar-camera") "Take photo"
              "button.outliner.editor.camera" "camera" send;
            toolbar_button model_source (`app "toolbar-audio") "Record audio"
              "button.outliner.editor.audio" "audio" send;
            toolbar_button model_source (`app "toolbar-attachment") "Upload asset"
              "button.outliner.editor.attachment" "attachment" send;
            toolbar_button model_source (`app "toolbar-page-reference")
              (View_base.tr (Signal.sample model_source) "Page reference")
              "button.outliner.editor.pageReference" "pageReference" send;
              ] ];
            toolbar_button model_source (`app "toolbar-hide-keyboard") "Hide keyboard"
              "button.outliner.editor.hideKeyboard" "hideKeyboard" send;
          ];
      ]
  else
    reactive ~equal:(fun before after -> View_base.outliner_editor_task_label before =
      View_base.outliner_editor_task_label after) (fun current ->
    let apple_icon_button icon label identifier action : toolbar_el =
      let label = View_base.tr current label in
      Lui_elements.toolbar_icon_button ~icon ~variant:`ghost ~width:38 ~height:42 ~label
        ~accessibility_identifier:identifier
        ~on_press:(fun _ ->
          ignore (send (Model.PerformOutlinerToolbarAction action)))
        []
    in
    toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Outliner editor")
      ~accessibility_identifier:"toolbar.outliner.editor"
      ~style_class:"scroll-leading leading-inset-8"
      ~toolbar_gap:4
      [
        apple_icon_button (`app "toolbar-task") (View_base.outliner_editor_task_label current)
          "button.outliner.editor.task" "task";
        if_toolbar ~test:show_task_dates (ios_date "scheduled" "Scheduled" "calendar");
        if_toolbar ~test:show_task_dates (ios_date "deadline" "Deadline" "deadline");
        apple_icon_button (`app "toolbar-outdent") "Outdent"
          "button.outliner.editor.outdent" "outdent";
        apple_icon_button (`app "toolbar-indent") "Indent"
          "button.outliner.editor.indent" "indent";
        apple_icon_button (`app "toolbar-move-up") "Move up"
          "button.outliner.editor.moveUp" "moveUp";
        apple_icon_button (`app "toolbar-move-down") "Move down"
          "button.outliner.editor.moveDown" "moveDown";
        toolbar_new_block;
        toolbar_line_break;
        apple_icon_button (`app "toolbar-tag") "Tag"
          "button.outliner.editor.tag" "tag";
        apple_icon_button (`app "toolbar-camera") "Take photo"
          "button.outliner.editor.camera" "camera";
        apple_icon_button (`app "toolbar-audio") "Record audio"
          "button.outliner.editor.audio" "audio";
        Lui_elements.toolbar_button ~variant:`ghost ~width:38 ~height:42
          ~label:(View_base.tr (Signal.sample model_source) "Page reference")
          ~accessibility_identifier:"button.outliner.editor.pageReference"
          ~on_press:(fun _ ->
            ignore
              (send
                 (Model.PerformOutlinerToolbarAction "pageReference")))
          ~text:(View_base.tr (Signal.sample model_source) "[[]]") [];
        Lui_elements.toolbar_icon_button ~icon:(`app "toolbar-hide-keyboard") ~variant:`ghost
          ~width:42 ~height:42 ~label:(View_base.tr (Signal.sample model_source) "Hide keyboard")
          ~accessibility_identifier:"button.outliner.editor.hideKeyboard"
          ~on_press:(fun _ ->
            ignore
              (send (Model.PerformOutlinerToolbarAction "hideKeyboard")))
          [];
      ]) model_source

let node_related_row ?(reference = false) ?(trailing_inset = 0) context model_source ~source:row_source send : t =
  let send action = send (match action with
    | Model.ToggleOutlinerCollapsed uuid when reference ->
      Model.ToggleReferenceCollapsed (uuid, not (Signal.sample row_source : Model.outline_row).is_collapsed)
    | action -> action) in
  let structured_breadcrumb_source =
    Signal.map (fun row -> row.Model.depth = 0 && View_base.outliner_row_structured_breadcrumb_ row) row_source
  in
  let fallback_breadcrumb_source =
    Signal.map (fun row -> row.Model.depth = 0 && View_base.outliner_row_fallback_breadcrumb_ row) row_source
  in
  let retained_row_source =
    Signal.map2
      (fun (current : Model.logseq_model) (r : Model.outline_row) ->
        View_rows.make_retained_outline_row current r)
      model_source row_source
  in
  column ~gap:0
    [
      if_ ~test:structured_breadcrumb_source
        (with_ios_trailing_padding (8 + trailing_inset) (box ~padding_horizontal:8
           [ box ~height:10 []; related_row_breadcrumbs model_source row_source send ]));
      if_ ~test:fallback_breadcrumb_source
        (with_ios_trailing_padding (8 + trailing_inset) (box ~padding_horizontal:8
           [
             box ~height:10 [];
             text
               ~value:
                 (reactive (Signal.map View_base.outliner_row_breadcrumb row_source))
               ~style_class:"caption" ~foreground:"muted-foreground" [];
           ]));
      outliner_row ~trailing_inset context model_source retained_row_source row_source
        send;
    ]

let related_section_heading title : t =
  box ~padding_horizontal:8
    [
      text ~style_class:"subheadline" ~foreground:"muted-foreground"
        ~accessibility_identifier:"title.related-section" ~value:title [];
    ]

let reference_entry context model_source entry_source send : t =
      (* The key fixes the entry kind; row values keep their own reactive bindings. *)
      match Signal.sample entry_source with
      | View_rows.Result_views _ ->
        let raw_source = Signal.map (function View_rows.Result_views value -> value | _ -> "") entry_source in
        box ~padding_horizontal:16 ~padding_vertical:12 [
          View_query.collection ~render_block:(render_result_block context model_source) model_source raw_source send]
      | View_rows.Reference_heading (key, title) ->
        let identifier =
          if key = "tagged" then "section.tag.tagged-nodes"
          else "section.node.linked-references"
        in
        column ~gap:0 ~padding_horizontal:8
          ~accessibility_identifier:identifier
          [ box ~height:26 []; related_section_heading (View_base.tr (Signal.sample model_source) title); box ~height:8 [] ]
      | View_rows.Empty_tag ->
        box ~padding_horizontal:16
          [ text ~foreground:"muted-foreground" ~value:(View_base.tr (Signal.sample model_source) "No tagged nodes") [] ]
      | View_rows.Reference_page (_, page) ->
        let page_source = Signal.map (function View_rows.Reference_page (_, page) -> page | _ -> page) entry_source in
        box ~padding_horizontal:16 ~margin_top:12
          ~accessibility_identifier:("reference.page." ^ page.uuid)
          [ node_breadcrumb_button model_source page_source send ]
      | View_rows.Reference_row (key, _) ->
        let inset = 8 in
        with_ios_trailing_padding 0 (box ~padding_horizontal:inset
          [ node_related_row ~reference:(key <> "tagged") ~trailing_inset:inset context model_source
              ~source:(reactive View_rows.reference_entry_row entry_source) send ])

let page_loading_view model_source : t =
  if_ ~test:(reactive View_base.page_loading_visible_ model_source)
    (row ~gap:8 ~cross:`center ~padding:16
       ~accessibility_identifier:"status.page-loading"
       [ spinner ~width:16 ~height:16 [];
         text ~foreground:"muted-foreground" ~value:(View_base.tr (Signal.sample model_source) "Loading blocks…") [] ])

let placeholder_block context model_source (value : View_rows.placeholder) show_button send : t =
  let placeholder : t = custom @@ fun mount_context parent ->
    let node = mount mount_context ?parent (box ~height:28
      ~accessibility_identifier:("button.outliner.placeholder." ^ value.parent_uuid)
      [row ~cross:`center ~gap:0 ~padding_vertical:2
        [box ~opacity:0.35 [icon ~name:(`app "outliner-bullet") ~width:24 ~height:24 ~foreground:"muted-foreground"
           ~accessibility_identifier:("outliner.placeholder.bullet." ^ value.parent_uuid) []];
         box ~grow:1.0 []]]) in
    Lui_ui.string_property mount_context node AccessibilityLabel "Add block";
    Lui_ui.bool_property mount_context node PressEnabled true;
    register_press mount_context node (fun _ -> ignore (send (Model.AddRootBlock value.parent_uuid)));
    node in
  let placeholder = box ~height:28 [if_ ~test:show_button placeholder] in
  match value.journal_heading with
  | None -> box ~padding_horizontal:8 [placeholder]
  | Some (title, day, divider) ->
    let parts = Signal.map (fun current -> View_base.journal_title_parts current (Some day) title) model_source in
    column ~padding_horizontal:8 ~gap:0 [
      (if divider then column ~gap:0 [box ~height:26 []; separator ~accessibility_identifier:"journal.divider" []; box ~height:26 []]
       else box []);
      (custom @@ fun mount_context parent ->
        let node = mount mount_context ?parent (View_base.with_label_signal
          (Signal.map2 View_base.journal_heading_label model_source parts)
          (box ~accessibility_identifier:("button.journal." ^ value.parent_uuid)
            ~padding_horizontal:(if Lui_ui.host context = KotlinHost then 12 else 8)
            [row ~gap:8 ~cross:`center (page_heading_text parts)])) in
        Lui_ui.bool_property mount_context node PressEnabled true;
        register_press mount_context node (fun _ -> ignore (send (Model.RequestAppNode value.parent_uuid)));
        node);
      page_title_spacer (); placeholder]

let journal_task_row context model_source task_source send =
  let decode task = Option.map (fun row -> {row with Model.row_list_number = None})
    (Response_snapshot.related_row (journal_task_field "block" task)) in
  match decode (Signal.sample task_source) with
  | None -> box []
  | Some initial ->
    let uuid = initial.row_uuid in
    let scope = Some (View_rows.journal_task_scope uuid) in
    let source = Signal.map (fun task -> Option.value ~default:initial (decode task)) task_source in
    let view_model = Signal.map (fun (model : Model.logseq_model) ->
      {model with node_icons = String_map.remove uuid model.node_icons}) model_source in
    let retained = Signal.map2 (View_rows.make_retained_outline_row ?edit_scope:scope) view_model source in
    let send_block = function
      | Model.DropOutlinerBlocks _ -> true
      | action -> send_scoped_outliner_edit scope send action in
    let metadata = reactive ~equal:(fun old current -> List.for_all (fun key ->
      journal_task_field key old = journal_task_field key current) ["scheduled"; "deadline"; "page"]) (fun task ->
      let current = Signal.sample model_source in
      let chip id ?icon_name ?overdue_signal ~label value on_press =
        View_property.compact_task_metadata ?icon_name ?overdue_signal ~label
          ~identifier:("journal-task." ^ id ^ "." ^ uuid)
          (Signal.constant context.Lui_ui.ui_scheduler value) on_press in
      let dates = List.filter_map (fun (key, name, image) ->
        match journal_task_field key task with
        | `Int date ->
          let overdue_signal = if key <> "deadline" then None else
            Some (Signal.map (fun (current : Model.logseq_model) ->
              match journal_task_field "day" current.journal_tasks with
              | `Int today -> View_property.task_date_overdue ~today date
              | _ -> false) model_source) in
          Some (chip key ~icon_name:image ?overdue_signal ~label:(View_base.tr current name)
            (View_property.task_date_label current date)
            (fun () -> ignore (send (Model.OpenBlockTaskDate (uuid, key)))))
        | _ -> None) task_date_fields in
      let page = task_text (journal_task_field "page" task) in
      let items = dates @ (if page = "" then [] else
        [chip "page" ~label:(View_base.tr_named current "Open {1}" page) page (fun () ->
          ignore (send (View_base.request_node_action (Signal.sample model_source) (Signal.sample source).page_id)))]) in
      let items = List.concat (List.mapi (fun index item ->
        if index = 0 then [item] else
          [text ~value:"·" ~style_class:"footnote" ~foreground:"muted-foreground" []; item]) items) in
      row ~gap:5 ~main:`start ~cross:`center
        ~accessibility_identifier:("journal-task.metadata." ^ uuid) items) task_source in
    let inset = 8 in
    with_ios_trailing_padding 0 (column ~gap:0 ~padding_horizontal:inset ~padding_vertical:1
      ~accessibility_identifier:(View_rows.journal_task_scope uuid) [
        outliner_row_body ~allow_drag:false ~trailing_inset:inset context view_model retained source send_block;
        View_base.with_int_prop_signal PaddingLeft
          (Signal.map (outliner_task_date_leading context) source)
          (with_ios_trailing_padding inset (box [metadata]));
      ])

let journal_task_entry context model_source send = function
  | View_rows.Journal_task_gap -> box ~height:80 []
  | View_rows.Journal_task_heading section ->
    let label = match section with
      | "overdue" -> "Overdue"
      | "doing" -> "Doing"
      | _ -> "Planned" in
    let collapsed = Signal.map (fun (model : Model.logseq_model) ->
      List.mem section (Model.journal_tasks_collapsed model)) model_source in
    let label = View_base.tr (Signal.sample model_source) label in
    let title = text ~value:label ~style_class:"semibold" ~foreground:"muted-foreground" [] in
    let chevron =
      if Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost then
        custom (fun context parent ->
          let node = Lui_ui.extension context "journal-task-chevron" in
          attach context parent node;
          Lui_ui.extension_property_signal context node "collapsed"
            (Signal.map (fun value -> BoolValue value) collapsed);
          ignore (mount context ~parent:node (icon ~name:(`app "chevron-right")
            ~width:14 ~height:14 ~foreground:"muted-foreground" []));
          node)
      else icon ~name:(`app "chevron-down")
        ~name_signal:(Signal.map (fun collapsed -> `app (if collapsed then "chevron-right" else "chevron-down")) collapsed)
        ~width:14 ~height:14 ~foreground:"muted-foreground" [] in
    let contents = if Lui_ui.host context = KotlinHost then
        [row ~gap:6 ~cross:`center [title; chevron]]
      else [title; box ~width:6 []; chevron] in
    box ~padding_horizontal:16 ~margin_top:12 [
      separator [];
      button ~variant:`ghost ~padding_horizontal:0 ~foreground:"muted-foreground"
        ~min_height:44 ~text_alignment:`start ~text:label ~label
        ~accessibility_identifier:("journal-tasks." ^ section)
        ~on_press:(fun _ -> ignore (send (Model.ToggleJournalTaskSection section))) contents;
    ]
  | View_rows.Journal_task_error ->
    let reason (current : Model.logseq_model) =
      if journal_task_field "retained" current.journal_tasks = `Bool true
      then "Couldn't refresh tasks" else "Couldn't load tasks" in
    let waiting = Signal.map (task_effect_active "journal-tasks.refresh") model_source in
    row ~gap:12 ~cross:`center ~padding_horizontal:16 ~padding_vertical:8 ~accessibility_identifier:"journal-tasks.error" [
      text ~grow:1.0 ~foreground:"muted-foreground" ~value:(reactive (fun current ->
        View_base.tr current (reason current)) model_source) [];
      button ~variant:`ghost ~min_height:44 ~text:(View_base.tr (Signal.sample model_source) "Retry")
        ~disabled_signal:waiting ~accessibility_identifier:"journal-tasks.retry"
        ~on_press:(fun _ -> ignore (send Model.RetryJournalTasks)) [];
    ]
  | _ -> box []

let with_journal_task_transition model_source content =
  custom @@ fun context parent ->
    match Lui_ui.platform context, Lui_ui.host context with
    | IOS, SwiftUIHost ->
      let node = Lui_ui.extension context "journal-task-transition" in
      attach context parent node;
      Lui_ui.extension_property_signal context node "collapsed"
        (Signal.map (fun model ->
          StringValue (String.concat "," (List.sort String.compare (Model.journal_tasks_collapsed model)))) model_source);
      ignore (mount context ~parent:node content);
      node
    | _ -> mount context ?parent content

let outliner_bottom_spacer () =
  let height = 120 in
  custom @@ fun context parent ->
    match Lui_ui.platform context, Lui_ui.host context with
    | IOS, SwiftUIHost ->
      let node = Lui_ui.extension context "outliner-bottom-spacer" in
      attach context parent node;
      Lui_ui.extension_property context node "height" (IntValue height);
      node
    | _ -> mount context ?parent (box ~height [])

let outliner_entries ?prefetch_history context model_source ~source send : t =
 custom @@ fun mount_context parent ->
  let previous_pin = ref None in
  let ios = Lui_ui.platform mount_context = IOS && Lui_ui.host mount_context = SwiftUIHost in
  let project_entries rows current =
    let entries = View_rows.page_entries rows current in
    if ios && View_base.journal_home_visible_ current then begin
      (* Keep the last edited row in its native slot as the editor becomes a
         read-only row. Swapping both identities makes the lazy list remeasure. *)
      let pin, entries = View_rows.retain_page_entry_pin !previous_pin entries in
      previous_pin := pin;
      entries
    end else begin
      previous_pin := None;
      entries
    end in
  let entries = Signal.own_signal mount_context.Lui_ui.ui_scope
    (Signal.map2 project_entries source model_source) in
  let first_section = Signal.own_signal mount_context.ui_scope
    (Signal.map View_rows.first_journal_section_count model_source) in
  let section_titles = Signal.own_signal mount_context.ui_scope
    (Signal.map View_rows.journal_section_titles model_source) in
  let ensure_content () =
    let requested = ref [] in
    fun entries ->
      let ids = List.filter_map View_rows.unloaded_entry_id entries in
      if ids <> !requested then begin
        requested := ids;
        if ids <> [] then ignore (send (Model.EnsureOutlinerRows ids))
      end in
  let on_window = ensure_content () in
  let on_prefetch = ensure_content () in
  let on_visible_range = match prefetch_history with
    | None -> fun _ _ -> ()
    | Some request ->
      let count = Signal.own_signal mount_context.ui_scope (Signal.map List.length entries) in
      let prefetched_through = ref (-1) in
      fun _ last ->
        (* Leave room for a flick to decelerate while older journals load. *)
        if last > !prefetched_through && Signal.sample count - last <= 12
           && request () then prefetched_through := last in
  let scroll_target = Signal.own_signal mount_context.ui_scope
    (Signal.map (fun (current : Model.logseq_model) ->
      match View_base.active_node_projection current with
      | Some route -> Option.map (fun uuid -> "outline." ^ uuid) route.Model.node_scroll_target | None -> None) model_source) in
  mount mount_context ?parent
    (View_rows.windowed_keyed ~scroll_target ~first_section ~section_titles ~on_window ~on_visible_range
      ~on_prefetch ~is_pinned:View_rows.page_entry_pinned_ ~source:entries
      ~key:View_rows.page_entry_identifier ~cmp:compare
      ~mount:(fun entry_source ->
        let render () = match Signal.sample entry_source with
        | View_rows.Outline_entry _ ->
          let retained = Signal.map View_rows.page_entry_outline entry_source in
          outliner_entry context model_source retained
            (Signal.map View_rows.retained_row_value retained) send
        | View_rows.Placeholder_entry value ->
          let show_button = Signal.map (function View_rows.Placeholder_entry value -> value.show_button
            | _ -> false) entry_source in
          placeholder_block context model_source value show_button send
        | View_rows.Reference_entry _ ->
          reference_entry context model_source
            (Signal.map View_rows.page_entry_reference entry_source) send
        | (View_rows.Journal_task_gap | View_rows.Journal_task_heading _ | View_rows.Journal_task_error) as entry ->
          journal_task_entry context model_source send entry
        | View_rows.Journal_task_row (initial, _) ->
          journal_task_row context model_source (Signal.map (function
            | View_rows.Journal_task_row (task, _) -> task | _ -> initial) entry_source) send in
        box ~padding:0
          [ reactive (fun ready -> if ready then render ()
              else box ~height:32 ~padding_horizontal:16
                ~accessibility_identifier:"outliner.row-loading"
                [box ~width:160 ~height:14 ~corner_radius:4 ~background:"muted" []])
              (Signal.map View_rows.page_entry_ready entry_source) ]) ())

let node_screen (context : Lui_ui.ui_context) model_source send : t =
  View_base.with_reading_insets
    (column ~accessibility_identifier:"screen.node"
    ~grow:(if Lui_ui.host context = KotlinHost then 1.0 else 0.0)
    [
      with_result_page context model_source send
      (with_journal_task_transition model_source
      (View_base.with_selected_signal (Signal.constant context.Lui_ui.ui_scheduler true)
      (virtual_list ~grow:1.0 ~gap:0 ~style_class:"scroll-section-titles" ~accessibility_identifier:"list.outliner"
        ~data_attrs_signal:(Signal.map (fun current ->
          ["data-scroll-identity", View_base.outliner_scroll_identity current]) model_source)
        [
          box ~height:16 [];
          if_ ~test:(reactive View_base.active_node_has_breadcrumbs_ model_source)
            (node_breadcrumbs model_source send);
          if_ ~test:(reactive View_base.node_title_visible_ model_source)
            (column ~gap:0
               [ box ~padding_horizontal:16 ~accessibility_identifier:"layout.node.title"
                   [ row ~gap:8 ~cross:`center (
                       View_base.node_icon_view ~size:28 (Signal.map (fun current ->
                         View_base.node_icon current (View_base.active_node_uuid current)) model_source)
                       :: page_heading_text ~accessibility_identifier:"title.node"
                         (Signal.map View_base.active_node_title_parts model_source)) ];
                 reactive (fun has_properties -> page_title_spacer ~has_properties ())
                   (Signal.map (fun model -> match View_base.active_node_projection model with
                     | Some route -> View_property.has_properties route.node_properties_json | None -> false) model_source) ]);
          page_loading_view model_source;
          if_ ~test:(Signal.map (fun (model : Model.logseq_model) ->
            match View_base.active_node_projection model with
            | Some route -> route.node_uuid = route.node_page_uuid | None -> false) model_source)
            (node_properties context model_source send);
          outliner_entries context model_source
            ~source:(reactive View_rows.retained_outliner_rows model_source) send;
          outliner_bottom_spacer ();
        ])));
    ])
