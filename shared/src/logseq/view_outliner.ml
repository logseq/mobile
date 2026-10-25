open Lui_protocol
open Lui_elements

let outliner_editor_view model_source block_id_source title_source caret_source send : t
    =
 fun context parent ->
   let node = Lui_ui.extension context "outliner-editor" in
   attach context parent node;
   Lui_ui.extension_property_signal context node "input-policy"
     (Signal.map2 (fun (current : Model.logseq_model) uuid ->
       let multiline = List.exists (fun (row : Model.outline_row) -> row.row_uuid = uuid
         && List.mem row.row_display_type [Some "code"; Some "math"]) current.outliner_rows in
       StringValue (if multiline then {|{"multiline":true,"emptyPairs":[{"text":"[[]]","deleteOffset":1}]}|}
         else Outliner_state.native_input_policy)) model_source block_id_source);
   Lui_ui.extension_property_signal context node "focus-enabled"
     (Signal.map (fun (current : Model.logseq_model) -> BoolValue
       (match current.outliner_autocomplete with
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

let outliner_rich_block_view model_source title_source markup_source
    youtube_target_source is_asset_source row_source asset_type_source
    local_path_source send : t =
 fun context parent ->
   let node = Lui_ui.extension context "outliner-block-content" in
   attach context parent node;
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
   Lui_ui.on_event context node (fun input_event ->
       ignore
         (View_base.handle_outliner_block_content_event input_event
            model_source send));
   node

let outliner_collapse_button (context : Lui_ui.ui_context) row_source send :
    t =
  let current_row = Signal.sample row_source in
  if Lui_ui.host context = KotlinHost then
    View_base.with_label_signal
      (Signal.map View_base.outliner_row_collapse_label row_source)
      (View_base.with_string_prop_signal InlineIconName
         (Signal.map
            (fun (current_row : Model.outline_row) ->
              View_base.outliner_collapse_icon_name
                current_row.is_collapsed)
            row_source)
         (button ~variant:`ghost ~width:24 ~height:24
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
      (Signal.map View_base.outliner_row_collapse_label row_source)
      (View_base.with_string_prop_signal InlineIconName
         (Signal.map
            (fun (current_row : Model.outline_row) ->
              if current_row.is_collapsed then "app:disclosure-right"
              else "app:disclosure-down")
            row_source)
         (button ~size:`icon ~style_class:"body-line"
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
 fun context parent ->
   let node = Lui_ui.text context "" in
   attach context parent node;
   Lui_ui.int_property_signal context node WidthValue width_source;
   node

let breadcrumb_button breadcrumb_source search_open send : t =
  let breadcrumb = Signal.sample breadcrumb_source in
  button
    ~text_signal:(reactive View_base.breadcrumb_title breadcrumb_source)
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
       ~text_signal:(reactive View_base.outliner_tag_title tag_source)
       ~style_class:"caption" ~variant:`ghost ~foreground:"link"
       ~height:22 ~padding_vertical:0
       ~accessibility_identifier:(View_base.outliner_tag_identifier tag)
       ~on_press:(fun _ ->
         ignore
           (send
              (View_base.request_node_action (Signal.sample model_source)
                (Signal.sample tag_source : Model.sidebar_page).uuid)))
       [context_menu [if_ ~test:(Signal.map (fun current -> Model.node_can_set_tags current owner) model_source)
         (menu_item ~text:(View_base.tr (Signal.sample model_source) "Remove tag") ~variant:`destructive
           ~accessibility_identifier:("button.block-tag.remove." ^ owner ^ "." ^ tag.uuid)
           ~on_press:(fun _ -> ignore (send (remove_node_tag (Signal.sample model_source) owner tag.uuid))) [])]])

let outliner_zoom_control (context : Lui_ui.ui_context) model_source
    row_source send search_open : t =
  let current_row = Signal.sample row_source in
  if Lui_ui.host context = KotlinHost then
    stack ~width:24 ~height:24
      [
        row ~width:24 ~height:24 ~main:`center ~cross:`center
          [
            if_ ~test:(Signal.map (fun (row : Model.outline_row) -> row.row_list_number <> None && not row.row_is_embed) row_source)
              (text ~value_signal:(Signal.map (fun (row : Model.outline_row) ->
                Option.fold ~none:"" ~some:(fun n -> string_of_int n ^ ".") row.row_list_number) row_source)
                ~font_size:"14" ~foreground:"muted-foreground"
                ~accessibility_identifier:("outliner.number." ^ View_base.outliner_row_uuid current_row) []);
            View_base.node_icon_view ~size:18 (Signal.map2 (fun current (row : Model.outline_row) ->
              View_base.outliner_node_icon current row) model_source row_source);
            if_ ~test:(Signal.map2 (fun current (row : Model.outline_row) ->
              View_base.outliner_node_icon current row = "" && row.row_list_number = None) model_source row_source)
            (icon ~name_signal:(Signal.map (fun (row : Model.outline_row) ->
                `app (if row.is_collapsed && row.has_children then "outliner-bullet-closed" else "outliner-bullet")) row_source)
              ~width:24 ~height:24 ~foreground:"border"
              ~accessibility_identifier:
                ("outliner.bullet-glyph."
                 ^ View_base.outliner_row_uuid current_row)
              []);
          ];
        View_base.with_label_signal
          (Signal.map View_base.outliner_row_zoom_label row_source)
          (button ~variant:`ghost ~width:24 ~height:24
             ~accessibility_identifier_signal:
               (Signal.map View_base.outliner_row_zoom_identifier
                  row_source)
             ~on_press:(fun _ ->
               ignore
                 (send
                    (if search_open then
                       Model.RequestSearchNode
                         (Signal.sample row_source : Model.outline_row).row_uuid
                     else
                       Model.RequestAppNode
                         (Signal.sample row_source : Model.outline_row).row_uuid)))
             []);
      ]
  else
    View_base.with_label_signal
      (Signal.map View_base.outliner_row_zoom_label row_source)
      (button ~icon:(`app "outliner-bullet") ~size:`icon
         ~style_class:"body-line" ~variant:`ghost ~foreground:"border"
         ~width:24 ~height:24
         ~accessibility_identifier_signal:
           (Signal.map View_base.outliner_row_zoom_identifier row_source)
         ~on_press:(fun _ ->
           ignore
             (send
                (if search_open then
                   Model.RequestSearchNode
                     (Signal.sample row_source : Model.outline_row).row_uuid
                 else
                   Model.RequestAppNode
                     (Signal.sample row_source : Model.outline_row).row_uuid)))
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
    context_menu
      [
        keyed
          ~source:(Signal.map View_base.model_task_statuses model_source)
          ~key:View_base.task_status_identifier ~cmp:compare
          ~mount:(fun status_source ->
            View_composer.outliner_task_status_row
              (View_base.outliner_row_uuid current_row) status_source send);
      ]
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
          (button ~variant:`ghost ~size:`icon ~width:24 ~height:24
             ~accessibility_identifier:"button.block-task-status"
             [ status_menu ]);
      ]
  else
    View_base.with_label_signal
      (Signal.map View_base.outliner_row_status_title row_source)
      (View_base.with_string_prop_signal InlineIconName
         (Signal.map View_base.outliner_task_status_icon row_source)
         (button ~variant:`ghost ~style_class:"body-line"
            ~foreground:"secondary" ~size:`icon ~width:22 ~height:24
            ~accessibility_identifier:"button.block-task-status"
            [ status_menu ]))

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
          [dropdown_menu [
            keyed ~source:(Signal.map (fun (m : Model.logseq_model) -> m.task_priorities) model_source)
              ~key:View_base.task_status_identifier ~cmp:compare ~mount:(fun choice_source ->
                let choice = Signal.sample choice_source in
                menu_item ~text_signal:(reactive (fun (p : Model.task_status) -> p.title) choice_source)
                  ~icon_signal:(Signal.map (fun p -> View_base.icon_of_wire_name (View_base.task_priority_icon_name p)) choice_source)
                  ~selected_signal:(Signal.map2 (fun (row : Model.outline_row) (p : Model.task_status) ->
                    Option.fold ~none:false ~some:(fun (selected : Model.task_status) -> selected.uuid = p.uuid) row.row_priority) row_source choice_source)
                  ~accessibility_identifier:("button.block-task-priority-option." ^ choice.uuid)
                  ~on_press:(fun _ -> choose (Signal.sample choice_source).uuid) []);
            menu_item ~text:(View_base.tr (Signal.sample model_source) "Clear priority")
              ~accessibility_identifier:"button.block-task-priority-clear" ~on_press:(fun _ -> choose "") []
          ]]))]

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
  let not_editing_source =
    Signal.map2
      (fun (current : Model.logseq_model) (r : Model.outline_row) ->
        View_base.row_not_editing_ current r)
      model_source row_source
  in
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
      column ~gap:2 ~grow:1.0 ~cross:`start
        ~accessibility_identifier:("outliner.title-and-tags." ^ current_row.row_uuid)
        [
          if_ ~test:editing_source
            (outliner_editor_view model_source block_id_source editing_title_source
               editing_caret_source send);
          if_ ~test:not_editing_source
            (outliner_rich_block_view model_source title_source
               markup_source youtube_target_source is_asset_source
               row_source asset_type_source local_path_source send);
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
           [ outliner_collapse_button context row_source send ]);
    ]

let outliner_row_content context model_source retained_row_source
    row_source send search_open : t =
  row ~gap:0 ~cross:`start ~padding_vertical:2
    [
      outliner_indent_view
        (Signal.map View_base.outliner_row_indent row_source);
      outliner_zoom_control context model_source row_source send
        search_open;
      box ~width:2 [];
      outliner_row_main_content context model_source retained_row_source
        row_source send;
    ]

let native_outliner_row model_source retained_source row_source send : t =
 fun context parent ->
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
      "canRemoveTags", `Bool (Model.node_can_set_tags current row.row_uuid);
      "removeTagTitle", `String (View_base.tr current "Remove tag");
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
  ignore ((if_ ~test:(reactive View_rows.retained_row_editing_ retained_source)
    (box ~padding:0 [outliner_editor_view model_source (Signal.map View_base.outliner_row_uuid row_source)
      (Signal.map View_rows.retained_row_editing_title retained_source)
      (Signal.map View_rows.retained_row_editing_caret retained_source) send])) context (Some node));
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
    | ExtensionEvent (_, _, "set-status", values) ->
      let index = match String_map.find_opt "count" values with Some (IntValue value) -> value | _ -> -1 in
      (match (if index < 0 then None else List.nth_opt (Signal.sample model_source).Model.task_statuses index) with
       | Some status -> ignore (send (Model.SetOutlinerTaskStatus ((Signal.sample row_source).row_uuid, status.uuid)))
       | None -> ())
    | input -> ignore (View_base.handle_outliner_block_content_event input model_source send));
  node

let selected_row ~selected_signal content =
  View_base.with_bool_prop_signal Selected selected_signal content

let outliner_row_body (context : Lui_ui.ui_context) model_source
    retained_row_source row_source send : t =
  let current_row = Signal.sample row_source in
  let search_open = (Signal.sample model_source : Model.logseq_model).search_open in
  if Lui_ui.host context = SwiftUIHost then
    selected_row ~selected:(reactive View_rows.retained_row_selected_ retained_row_source)
      (box ~padding:0 ~accessibility_identifier:(reactive View_base.outliner_row_identifier row_source)
        [native_outliner_row model_source retained_row_source row_source send])
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
            outliner_zoom_control context model_source row_source send
              search_open;
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
                retained_row_source row_source send search_open;
            ]))

let outliner_text_leading context (row : Model.outline_row) =
  let status = row.row_status <> None and priority = row.row_priority <> None in
  let leading = if Lui_ui.host context = KotlinHost then
    26 + (if status then 31 else 0) + (if priority then 27 else 0)
  else (if status then 49 else if priority then 20 else 26) + (if priority then 25 else 0) in
  leading + row.depth * 22

let outliner_continuation ?(is_body = false) row_source content : t = fun context parent ->
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
  ignore (content context (Some node));
  node

let outliner_task_dates context model_source row_source send =
  View_base.with_int_prop_signal PaddingLeft
    (Signal.map (outliner_text_leading context) row_source)
    (box ~padding_horizontal:8 [View_property.view ~compact:true ~render_block:(fun _ _ -> box [])
      model_source (Signal.map (fun (row : Model.outline_row) -> row.row_task_dates_json) row_source) send])

let row_metadata (row : Model.outline_row) =
  try Yojson.Basic.from_string row.row_metadata_json with _ -> `Null

let metadata_member key row =
  match row_metadata row with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields) | _ -> `Null

let code_language_control model_source row_source send : t =
  let row = Signal.sample row_source in
  let language row =
    try match Yojson.Basic.from_string row.Model.markup_json with
      | `List (`Assoc fields :: _) -> (match List.assoc_opt "style" fields with Some (`String language) -> language | _ -> "")
      | _ -> "" with _ -> "" in
  if_ ~test:(Signal.map (fun (row : Model.outline_row) -> row.row_display_type = Some "code") row_source)
    (box ~padding_horizontal:32 [
      menu_trigger ~text_signal:(Signal.map (fun row -> let value = language row in if value = "" then View_base.tr (Signal.sample model_source) "Plain text" else value) row_source)
        ~label:(View_base.tr (Signal.sample model_source) "Code language")
        ~accessibility_identifier:("button.outliner.code-language." ^ row.row_uuid)
        [dropdown_menu (List.map (fun (value, label) ->
          menu_item ~text:(View_base.tr (Signal.sample model_source) label) ~accessibility_identifier:("button.outliner.code-language.option." ^ value)
            ~on_press:(fun _ ->
              let row = Signal.sample row_source in
              ignore (send (Model.SubmitNodeProperty (row.row_uuid, Yojson.Basic.to_string (`Assoc [
                "action", `String "setCodeLanguage"; "blockUuid", `String row.row_uuid; "value", `String value]))))) [])
          ["", "Plain text"; "bash", "Bash"; "c", "C"; "cpp", "C++"; "clojure", "Clojure";
           "css", "CSS"; "go", "Go"; "html", "HTML"; "java", "Java"; "javascript", "JavaScript";
           "json", "JSON"; "kotlin", "Kotlin"; "markdown", "Markdown"; "ocaml", "OCaml";
           "python", "Python"; "ruby", "Ruby"; "rust", "Rust"; "sql", "SQL"; "swift", "Swift";
           "typescript", "TypeScript"; "yaml", "YAML"; "calc", "Calculator"]) ] ])

let discussion_body model_source row_source body : t =
  let row = Signal.sample row_source in
  dyn (fun kind ->
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
          text ~value_signal:(Signal.map (fun value ->
            let open Yojson.Basic.Util in
            let emoji = try value |> member "emoji" |> to_string with _ -> "" in
            let count = try value |> member "count" |> to_int with _ -> 0 in
            emoji ^ " " ^ string_of_int count) source)
            ~padding_horizontal:8 ~padding_vertical:4 ~corner_radius:8
            ~background:"muted" ~style_class:"caption" [])])

let decorate_row model_source row_source send body =
  column ~gap:0 [code_language_control model_source row_source send; discussion_body model_source row_source body; reaction_strip row_source]

let render_result_block context model_source row_source send =
    let retained = Signal.map2 View_rows.make_retained_outline_row model_source row_source in
    column ~gap:0 [
      if_ ~test:(Signal.map View_base.outliner_row_structured_breadcrumb_ row_source)
        (scroll ~orientation:`horizontal ~height:28 [related_row_breadcrumbs model_source row_source send]);
      if_ ~test:(Signal.map View_base.outliner_row_fallback_breadcrumb_ row_source)
        (text ~value_signal:(Signal.map View_base.outliner_row_breadcrumb row_source)
          ~style_class:"caption" ~foreground:"muted-foreground" []);
      (let body = decorate_row model_source row_source send (outliner_row_body context model_source retained row_source send) in
       if Lui_ui.host context = KotlinHost then outliner_continuation ~is_body:true row_source body else body);
      outliner_continuation row_source (outliner_task_dates context model_source row_source send)]

let node_properties ?(root = false) context model_source send =
  View_property.view ~render_block:(render_result_block context model_source) model_source
    (Signal.map (fun (model : Model.logseq_model) -> if root then model.properties_json else match View_base.active_node_projection model with
      | Some route -> route.node_properties_json | None -> model.properties_json) model_source) send

let outliner_row context model_source retained_row_source row_source send : t =
  let body = outliner_row_body context model_source retained_row_source row_source send in
  let body = decorate_row model_source row_source send body in
  let body = if Lui_ui.host context = KotlinHost then outliner_continuation ~is_body:true row_source body else body in
  let render_block = render_result_block context model_source in
  let bullet_inset = if Lui_ui.host context = KotlinHost then 12 else 20 in
  dyn (fun (has_query, has_properties, has_dates) ->
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
    column ~gap:0 [body; outliner_continuation row_source (column ~gap:0 (dates @ properties @ query))])
    (Signal.map2 (fun (model : Model.logseq_model) (row : Model.outline_row) ->
      row.query_json <> "", (match View_base.active_node_projection model with
      | Some route -> route.node_uuid = row.row_uuid && route.node_uuid <> route.node_page_uuid
        && View_property.has_properties route.node_properties_json
      | None -> false), View_property.has_properties row.row_task_dates_json) model_source row_source)

let journal_heading model_source row_source send children : t =
 fun context parent ->
  let node =
    (View_base.with_label_signal
       (Signal.map2 View_base.outliner_journal_accessibility_label
          model_source row_source)
       (box ~padding:0
          ~accessibility_identifier_signal:
            (Signal.map2 View_base.outliner_journal_button_identifier
               model_source row_source)
          children)) context parent
  in
  Lui_ui.bool_property context node PressEnabled true;
  register_press context node (fun _ ->
    ignore (send (Model.RequestAppNode
      (View_base.outliner_journal_page_id
         (Signal.sample model_source) (Signal.sample row_source)))));
  node

let outliner_entry context model_source retained_row_source row_source
    send : t =
  column ~padding_horizontal:8
    ~accessibility_identifier_signal:(Signal.map (fun (row : Model.outline_row) -> "outliner.entry." ^ row.row_uuid) row_source)
    [
      if_
        ~test:
          (Signal.map2
             (fun (current : Model.logseq_model) (r : Model.outline_row) ->
               View_base.outliner_journal_divider_visible_ current r)
             model_source row_source)
        (column ~gap:0
           [ box ~height:26 [];
             separator ~accessibility_identifier:"journal.divider" [] ]);
      if_
        ~test:
          (Signal.map2
             (fun (current : Model.logseq_model) (r : Model.outline_row) ->
               View_base.outliner_journal_heading_visible_ current r)
             model_source row_source)
        (journal_heading model_source row_source send
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
                 row ~gap:8 ~cross:`center [
                 View_base.node_icon_view ~size:28 (Signal.map2 (fun current row ->
                   View_base.node_icon current (View_base.outliner_journal_page_id current row)) model_source row_source);
                 heading ~level:3 ~style_class:"scroll-section-title"
                   ~value_signal:
                     (Signal.map2
                        (fun (current : Model.logseq_model)
                             (r : Model.outline_row) ->
                          View_base.outliner_journal_title current r)
                        model_source row_source)
                   []];
                 box ~height:12 [];
               ];
           ]);
      outliner_row context model_source retained_row_source row_source
        send;
    ]


let toolbar_button model_source icon label identifier action send : t =
  button ~icon ~variant:`ghost ~size:`icon ~width:48 ~height:48
    ~label ~accessibility_identifier:identifier
    ~on_press:(fun _ ->
      ignore (send (Model.PerformOutlinerToolbarAction action)))
    []

let outliner_selection_toolbar (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    box
      ~accessibility_identifier:"surface.outliner.selection-toolbar"
      [
        toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Outliner selection")
          ~accessibility_identifier:"toolbar.outliner.selection"
          ~style_class:"scroll-leading" ~toolbar_gap:4
          [
            toolbar_button model_source (`app "toolbar-copy") "Copy"
              "button.outliner.selection.copy" "copy" send;
            toolbar_button model_source (`app "toolbar-outdent") "Outdent"
              "button.outliner.selection.outdent" "outdent" send;
            toolbar_button model_source (`app "toolbar-indent") "Indent"
              "button.outliner.selection.indent" "indent" send;
            toolbar_button model_source (`app "toolbar-delete") "Delete"
              "button.outliner.selection.delete" "delete" send;
            toolbar_button model_source (`app "toolbar-copy-reference") "Copy reference"
              "button.outliner.selection.copyReference" "copyReference"
              send;
            toolbar_button model_source (`app "toolbar-copy-url") "Copy URL"
              "button.outliner.selection.copyURL" "copyURL" send;
            toolbar_button model_source (`app "toolbar-unselect") "Unselect"
              "button.outliner.selection.unselect" "unselect" send;
          ];
      ]
  else
    let apple_button icon label identifier action : t =
      View_base.with_int_prop_signal WidthValue
        (Signal.map (fun (current : Model.logseq_model) ->
          if current.viewport_width >= Model.wide_content_breakpoint then 58
          else if current.viewport_width >= 390 then 50 else 46) model_source)
        (button ~icon ~variant:`ghost ~height:46
        ~icon_placement:`top ~label
        ~accessibility_identifier:identifier
        ~on_press:(fun _ ->
          ignore (send (Model.PerformOutlinerToolbarAction action)))
        ~text:label [])
    in
    toolbar ~orientation:`horizontal ~label:(View_base.tr (Signal.sample model_source) "Outliner selection")
         ~accessibility_identifier:"toolbar.outliner.selection"
         ~style_class:"scroll-leading"
         ~toolbar_gap:2 ~placement:"bottom"
      [
        apple_button (`app "toolbar-copy") "Copy"
          "button.outliner.selection.copy" "copy";
        apple_button (`app "toolbar-outdent") "Outdent"
          "button.outliner.selection.outdent" "outdent";
        apple_button (`app "toolbar-indent") "Indent"
          "button.outliner.selection.indent" "indent";
        apple_button (`app "toolbar-delete") "Delete"
          "button.outliner.selection.delete" "delete";
        apple_button (`app "toolbar-copy-reference") "Copy reference"
          "button.outliner.selection.copyReference" "copyReference";
        apple_button (`app "toolbar-copy-url") "Copy URL"
          "button.outliner.selection.copyURL" "copyURL";
        button ~icon:(`app "toolbar-unselect") ~variant:`ghost ~width:52
          ~height:46 ~icon_placement:`top ~label:(View_base.tr (Signal.sample model_source) "Unselect")
          ~accessibility_identifier:"button.outliner.selection.unselect"
          ~on_press:(fun _ ->
            ignore
              (send (Model.PerformOutlinerToolbarAction "unselect")))
          ~text:(View_base.tr (Signal.sample model_source) "Unselect") [];
      ]

let outliner_autocomplete_row (context : Lui_ui.ui_context)
    ~node_labels candidate_source send : t =
  let candidate = Signal.sample candidate_source in
  let choose () = ignore (send (Model.ChooseOutlinerAutocomplete
    (Signal.sample candidate_source : Model.outliner_autocomplete_candidate).candidate_value)) in
  let reference_label context parent =
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
  column ~gap:0 ~grow:0.0 ~cross:`stretch [
  dyn (fun (candidate : Model.outliner_autocomplete_candidate) -> match candidate.candidate_group with
    | None -> box []
    | Some group -> text ~value:group ~font_size:"12" ~foreground:"muted-foreground"
        ~padding_horizontal:10 ~padding_vertical:5
        ~accessibility_identifier:("outliner.autocomplete.group." ^ group) []) candidate_source;
  row ~height:44 ~grow:0.0 ~cross:`center [View_base.with_label_signal
    (Signal.map View_base.outliner_autocomplete_label candidate_source)
    (View_base.with_string_prop_signal AccessibilityIdentifier
      (Signal.map View_base.outliner_autocomplete_identifier candidate_source)
    (button
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
    if form then (fun context parent ->
      let temporal = List.mem kind ["date"; "deadline"; "scheduled"] in
      let date_kind = if kind = "date" then "date" else "datetime" in
      let value = Signal.state context.Lui_ui.ui_scheduler (if temporal then View_query.temporal_default date_kind else "") in
      let label = Signal.state context.ui_scheduler "" in
      let input state = function TextChanged (_, value) -> Signal.set state value | _ -> () in
      let confirm _ =
        let value = Signal.sample (Signal.value value) in
        let value = if kind = "link" || kind = "image" then Yojson.Basic.to_string (`Assoc
          ["url", `String value; "label", `String (Signal.sample (Signal.value label))]) else value in
        emit "submitAutocomplete" value in
      let cancel = button ~text:(View_base.tr (Signal.sample model_source) "Cancel") ~variant:`ghost ~style_class:"cancellation-action"
        ~accessibility_identifier:"button.outliner.autocomplete.dismiss" ~on_press:(fun _ -> dismiss ()) [] in
      let done_ = button ~text:(View_base.tr (Signal.sample model_source) "Insert") ~variant:`ghost ~style_class:"confirmation-action"
        ~accessibility_identifier:"button.outliner.autocomplete.submit" ~on_press:confirm [] in
      (sheet ~text:(title kind) ~detents:"medium,large" ~style_class:"navigation-list navigation-inline-title"
        ~accessibility_identifier:"sheet.outliner.autocomplete" ~on_dismiss:(fun _ -> dismiss ()) [
        list ~grow:1.0 ~style:`inset_grouped [list_section (
          if temporal then [list_item ~padding_horizontal:0 ~padding_vertical:0 [
            View_query.temporal_picker date_kind "editor-command" (Signal.value value) (Signal.set value)]]
          else [list_item [text_field ~text_signal:(Signal.value value) ~autofocus:true
            ~placeholder:(if kind = "youtube" then "1:32" else "https://example.com")
            ~label:(if kind = "youtube" then "Timestamp" else "URL")
            ~accessibility_identifier:"field.outliner.autocomplete.value" ~on_input:(input value) []]]
          @ (if kind = "link" || kind = "image" then [list_item [text_field ~text_signal:(Signal.value label)
            ~placeholder:(View_base.tr (Signal.sample model_source) "Label (optional)") ~label:(View_base.tr (Signal.sample model_source) "Label") ~accessibility_identifier:"field.outliner.autocomplete.label"
            ~on_input:(input label) []]] else []))];
        (if Lui_ui.host context = KotlinHost then row ~main:`space_between ~padding:12 [cancel; done_]
         else toolbar ~label:(View_base.tr (Signal.sample model_source) "Insert content") ~style_class:"navigation-actions" [cancel; done_]);
      ]) context parent)
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
            ~on_input:(function TextChanged (_, value) -> emit "searchAutocomplete" value | _ -> ()) []
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
              (button ~icon:(reactive task_icon model_source)
                 ~foreground:(reactive task_foreground model_source)
                 ~variant:`ghost
                 ~size:`icon ~width:48 ~height:48
                 ~accessibility_identifier:"button.outliner.editor.task"
                 ~on_press:(fun _ ->
                   ignore
                     (send
                        (Model.PerformOutlinerToolbarAction "task")))
                 []);
            toolbar_button model_source (`app "toolbar-outdent") "Outdent"
              "button.outliner.editor.outdent" "outdent" send;
            toolbar_button model_source (`app "toolbar-indent") "Indent"
              "button.outliner.editor.indent" "indent" send;
            toolbar_button model_source (`app "toolbar-move-up") "Move up"
              "button.outliner.editor.moveUp" "moveUp" send;
            toolbar_button model_source (`app "toolbar-move-down") "Move down"
              "button.outliner.editor.moveDown" "moveDown" send;
            toolbar_button model_source (`app "toolbar-tag") "Tag"
              "button.outliner.editor.tag" "tag" send;
            toolbar_button model_source (`app "toolbar-camera") "Photo"
              "button.outliner.editor.camera" "camera" send;
            toolbar_button model_source (`app "toolbar-audio") "Record audio"
              "button.outliner.editor.audio" "audio" send;
            toolbar_button model_source (`app "toolbar-attachment") "Upload asset"
              "button.outliner.editor.attachment" "attachment" send;
            button ~variant:`ghost ~size:`icon ~width:48 ~height:48
              ~label:(View_base.tr (Signal.sample model_source) "Page reference")
              ~accessibility_identifier:
                "button.outliner.editor.pageReference"
              ~on_press:(fun _ ->
                ignore
                  (send
                     (Model.PerformOutlinerToolbarAction "pageReference")))
              ~text:(View_base.tr (Signal.sample model_source) "[[]]") [];
              ] ];
            toolbar_button model_source (`app "toolbar-hide-keyboard") "Hide keyboard"
              "button.outliner.editor.hideKeyboard" "hideKeyboard" send;
          ];
      ]
  else
    let apple_icon_button icon label identifier action : t =
      button ~icon ~variant:`ghost ~width:38 ~height:42 ~label
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
        View_base.with_label_signal
          (Signal.map View_base.outliner_editor_task_label model_source)
          (apple_icon_button (`app "toolbar-task") ""
             "button.outliner.editor.task" "task");
        apple_icon_button (`app "toolbar-outdent") "Outdent"
          "button.outliner.editor.outdent" "outdent";
        apple_icon_button (`app "toolbar-indent") "Indent"
          "button.outliner.editor.indent" "indent";
        apple_icon_button (`app "toolbar-move-up") "Move up"
          "button.outliner.editor.moveUp" "moveUp";
        apple_icon_button (`app "toolbar-move-down") "Move down"
          "button.outliner.editor.moveDown" "moveDown";
        apple_icon_button (`app "toolbar-tag") "Tag"
          "button.outliner.editor.tag" "tag";
        apple_icon_button (`app "toolbar-camera") "Photo"
          "button.outliner.editor.camera" "camera";
        apple_icon_button (`app "toolbar-audio") "Record audio"
          "button.outliner.editor.audio" "audio";
        button ~variant:`ghost ~width:38 ~height:42
          ~label:(View_base.tr (Signal.sample model_source) "Page reference")
          ~accessibility_identifier:"button.outliner.editor.pageReference"
          ~on_press:(fun _ ->
            ignore
              (send
                 (Model.PerformOutlinerToolbarAction "pageReference")))
          ~text:(View_base.tr (Signal.sample model_source) "[[]]") [];
        button ~icon:(`app "toolbar-hide-keyboard") ~variant:`ghost
          ~width:42 ~height:42 ~label:(View_base.tr (Signal.sample model_source) "Hide keyboard")
          ~accessibility_identifier:"button.outliner.editor.hideKeyboard"
          ~on_press:(fun _ ->
            ignore
              (send (Model.PerformOutlinerToolbarAction "hideKeyboard")))
          [];
      ]

let node_related_row context model_source ~source:row_source send : t =
  let structured_breadcrumb_source =
    Signal.map View_base.outliner_row_structured_breadcrumb_ row_source
  in
  let fallback_breadcrumb_source =
    Signal.map View_base.outliner_row_fallback_breadcrumb_ row_source
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
        (box ~padding_horizontal:8
           [ box ~height:10 []; related_row_breadcrumbs model_source row_source send ]);
      if_ ~test:fallback_breadcrumb_source
        (box ~padding_horizontal:8
           [
             box ~height:10 [];
             text
               ~value_signal:
                 (Signal.map View_base.outliner_row_breadcrumb row_source)
               ~style_class:"caption" ~foreground:"muted-foreground" [];
           ]);
      outliner_row context model_source retained_row_source row_source
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
      | View_rows.Reference_row _ ->
        box ~padding_horizontal:8
          [ node_related_row context model_source
              ~source:(reactive View_rows.reference_entry_row entry_source) send ]

let page_loading_view model_source : t =
  if_ ~test:(reactive View_base.page_loading_visible_ model_source)
    (row ~gap:8 ~cross:`center ~padding:16
       ~accessibility_identifier:"status.page-loading"
       [ spinner ~width:16 ~height:16 [];
         text ~foreground:"muted-foreground" ~value:(View_base.tr (Signal.sample model_source) "Loading blocks…") [] ])

let placeholder_block context model_source (value : View_rows.placeholder) send : t =
  let placeholder : t = fun mount_context parent ->
    let node = box ~height:28
      ~accessibility_identifier:("button.outliner.placeholder." ^ value.parent_uuid)
      [row ~cross:`center ~gap:0 ~padding_vertical:2
        [box ~opacity:0.35 [icon ~name:(`app "outliner-bullet") ~width:24 ~height:24 ~foreground:"muted-foreground"
           ~accessibility_identifier:("outliner.placeholder.bullet." ^ value.parent_uuid) []];
         box ~grow:1.0 []]] mount_context parent in
    Lui_ui.string_property mount_context node AccessibilityLabel "Add block";
    Lui_ui.bool_property mount_context node PressEnabled true;
    register_press mount_context node (fun _ -> ignore (send (Model.AddRootBlock value.parent_uuid)));
    node in
  let placeholder = box ~height:28 [
    if_ ~test:(Signal.map (fun (current : Model.logseq_model) ->
      match current.outliner_editing with
      | None -> true
      | Some editing -> List.exists (fun (row : Model.outline_row) ->
          row.row_uuid = editing.editing_uuid && List.mem row.row_display_type [Some "math"; Some "code"])
          current.outliner_rows) model_source) placeholder] in
  match value.journal_heading with
  | None -> box ~padding_horizontal:8 [placeholder]
  | Some (title, _, divider) ->
    column ~padding_horizontal:8 ~gap:0 [
      (if divider then column ~gap:0 [box ~height:26 []; separator ~accessibility_identifier:"journal.divider" []; box ~height:26 []]
       else box []);
      (fun mount_context parent ->
        let node = View_base.with_label_signal
          (Signal.constant mount_context.Lui_ui.ui_scheduler ("Open " ^ title))
          (box ~accessibility_identifier:("button.journal." ^ value.parent_uuid)
            ~padding_horizontal:(if Lui_ui.host context = KotlinHost then 12 else 8)
            [heading ~level:3 ~style_class:"scroll-section-title" ~value:title []]) mount_context parent in
        Lui_ui.bool_property mount_context node PressEnabled true;
        register_press mount_context node (fun _ -> ignore (send (Model.RequestAppNode value.parent_uuid)));
        node);
      box ~height:12 []; placeholder]

let outliner_entries context model_source ~source send : t =
 fun mount_context parent ->
  let entries = Signal.own_signal mount_context.Lui_ui.ui_scope
    (Signal.map2 View_rows.page_entries source model_source) in
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
  let scroll_target = Signal.own_signal mount_context.ui_scope
    (Signal.map (fun current -> match View_base.active_node_projection current with
      | Some route -> Option.map (fun uuid -> "outline." ^ uuid) route.Model.node_scroll_target | None -> None) model_source) in
  View_rows.windowed_keyed ~scroll_target ~first_section ~section_titles ~on_window
    ~on_prefetch ~is_pinned:View_rows.page_entry_editor_ ~source:entries
    ~key:View_rows.page_entry_identifier ~cmp:compare
    ~mount:(fun entry_source ->
      let render () = match Signal.sample entry_source with
      | View_rows.Outline_entry _ ->
        let retained = Signal.map View_rows.page_entry_outline entry_source in
        outliner_entry context model_source retained
          (Signal.map View_rows.retained_row_value retained) send
      | View_rows.Placeholder_entry value -> placeholder_block context model_source value send
      | View_rows.Reference_entry _ ->
        reference_entry context model_source
          (Signal.map View_rows.page_entry_reference entry_source) send in
      box ~padding:0
        [ reactive (fun ready -> if ready then render ()
            else box ~height:32 ~padding_horizontal:16
              ~accessibility_identifier:"outliner.row-loading"
              [box ~width:160 ~height:14 ~corner_radius:4 ~background:"muted" []])
            (Signal.map View_rows.page_entry_ready entry_source) ])
    mount_context parent

let node_screen (context : Lui_ui.ui_context) model_source send : t =
  View_base.with_reading_insets
    (column ~accessibility_identifier:"screen.node"
    ~grow:(if Lui_ui.host context = KotlinHost then 1.0 else 0.0)
    [
      View_base.with_selected_signal (Signal.constant context.Lui_ui.ui_scheduler true)
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
                   [ row ~gap:8 ~cross:`center [
                       View_base.node_icon_view ~size:28 (Signal.map (fun current ->
                         View_base.node_icon current (View_base.active_node_uuid current)) model_source);
                       heading ~level:3 ~style_class:"scroll-section-title" ~value:(reactive View_base.active_node_title model_source)
                         ~accessibility_identifier:"title.node" [] ] ];
                 dyn (fun has_properties -> box ~height:(if has_properties then 16 else 12) [])
                   (Signal.map (fun model -> match View_base.active_node_projection model with
                     | Some route -> View_property.has_properties route.node_properties_json | None -> false) model_source) ]);
          page_loading_view model_source;
          if_ ~test:(Signal.map (fun (model : Model.logseq_model) ->
            match View_base.active_node_projection model with
            | Some route -> route.node_uuid = route.node_page_uuid | None -> false) model_source)
            (node_properties context model_source send);
          outliner_entries context model_source
            ~source:(reactive View_rows.retained_outliner_rows model_source) send;
          box ~height:120 [];
        ]);
    ])
