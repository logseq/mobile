open Lui_protocol
open Lui_elements

let outliner_editor_view block_id_source title_source caret_source send : t
    =
 fun context parent ->
   let node = Lui_ui.extension context "outliner-editor" in
   attach context parent node;
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
         (button ~variant:`ghost ~width:28 ~height:28
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
            ~foreground:"secondary" ~variant:`ghost ~width:28 ~height:24
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

let related_row_breadcrumbs row_source send : t =
  breadcrumb ~gap:5 ~main:`start
    ~accessibility_identifier:"breadcrumb.related-blocks"
    [
      keyed
        ~source:(Signal.map View_base.outliner_row_breadcrumbs row_source)
        ~key:View_base.breadcrumb_identifier ~cmp:compare
        ~mount:(fun breadcrumb_source ->
          breadcrumb_button breadcrumb_source false send);
    ]

let outliner_tag tag_source send : t =
  let tag = Signal.sample tag_source in
  View_base.with_label_signal
    (Signal.map View_base.outliner_tag_title tag_source)
    (button
       ~text_signal:(reactive View_base.outliner_tag_title tag_source)
       ~style_class:"caption" ~variant:`ghost ~foreground:"accent"
       ~height:22 ~padding_vertical:0
       ~accessibility_identifier:(View_base.outliner_tag_identifier tag)
       ~on_press:(fun _ ->
         ignore
           (send
              (Model.RequestAppNode (Signal.sample tag_source : Model.sidebar_page).uuid)))
       [])

let outliner_zoom_control (context : Lui_ui.ui_context) model_source
    row_source send search_open : t =
  let current_row = Signal.sample row_source in
  if Lui_ui.host context = KotlinHost then
    stack ~width:24 ~height:24
      [
        row ~width:24 ~height:24 ~main:`center ~cross:`center
          [
            icon ~name_signal:(Signal.map (fun (row : Model.outline_row) ->
                `app (if row.is_collapsed && row.has_children then "outliner-bullet-closed" else "outliner-bullet")) row_source)
              ~width:24 ~height:24 ~foreground:"border"
              ~accessibility_identifier:
                ("outliner.bullet-glyph."
                 ^ View_base.outliner_row_uuid current_row)
              [];
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
      reactive (fun (row : Model.outline_row) ->
        match row.row_priority with
        | None -> box []
        | Some priority ->
          let ident = Option.value ~default:"" priority.ident in
          let level = match List.rev (String.split_on_char '/' ident) with
            | name :: _ when name <> "" -> name | _ -> String.lowercase_ascii priority.title in
          icon ~name:(`app ("priority-" ^ level)) ~width:20 ~height:24
            ~foreground:"muted-foreground" ~tooltip:priority.title []) row_source;
      column ~gap:2 ~grow:1.0 ~cross:`start
        ~accessibility_identifier:("outliner.title-and-tags." ^ current_row.row_uuid)
        [
          if_ ~test:editing_source
            (outliner_editor_view block_id_source editing_title_source
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
                   ~mount:(fun tag_source -> outliner_tag tag_source send);
               ]);
          if_ ~test:sync_failed_source
            (text
               ~accessibility_identifier:
                 ("outliner.sync-failed."
                  ^ View_base.outliner_row_uuid current_row)
               ~value:"Sync failed" []);
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
      "markup", (try Yojson.Basic.from_string row.markup_json with _ -> `List []);
      "depth", `Int row.depth; "hasChildren", `Bool row.has_children;
      "collapsed", `Bool row.is_collapsed; "isAsset", `Bool row.is_asset;
      "assetType", `String (View_base.outliner_row_asset_type row);
      "localPath", `String (View_base.outliner_row_local_path row);
      "youtubeURL", `String (View_base.outliner_row_youtube_target row);
      "completed", `Bool (View_base.outliner_row_completed_ row);
      "selected", `Bool (View_base.row_selected_ current row);
      "opensAsPage", `Bool row.opens_as_page;
      "journalBullet", `Bool false;
      "syncFailed", `Bool (View_base.outliner_row_sync_failed_ row);
      "priority", (match row.row_priority with
        | None -> `Null
        | Some priority ->
          let ident = Option.value ~default:"" priority.ident in
          let level = match String.split_on_char '.' ident |> List.rev with value :: _ -> value | [] -> "none" in
          `Assoc ["uuid", `String priority.uuid; "title", `String priority.title;
            "icon", `String ("app:priority-" ^ level)]);
      "status", (match row.row_status with Some value -> status value | None -> `Null);
      "statuses", `List (List.map status current.task_statuses);
      "tags", `List (List.map summary row.tags)]) in
  Lui_ui.extension_property_signal context node "payload"
    (Signal.map2 (fun current retained -> StringValue (payload current retained)) model_source retained_source);
  ignore ((if_ ~test:(reactive View_rows.retained_row_editing_ retained_source)
    (box ~padding:0 [outliner_editor_view (Signal.map View_base.outliner_row_uuid row_source)
      (Signal.map View_rows.retained_row_editing_title retained_source)
      (Signal.map View_rows.retained_row_editing_caret retained_source) send])) context (Some node));
  Lui_ui.on_event context node (function
    | ExtensionEvent (_, _, "collapse", _) -> ignore (send (Model.ToggleOutlinerCollapsed (Signal.sample row_source).row_uuid))
    | ExtensionEvent (_, _, "long-press", _) -> ignore (send (Model.LongPressOutlinerBlock (Signal.sample row_source).row_uuid))
    | ExtensionEvent (_, _, "set-status", values) ->
      let index = match String_map.find_opt "count" values with Some (IntValue value) -> value | _ -> -1 in
      (match (if index < 0 then None else List.nth_opt (Signal.sample model_source).Model.task_statuses index) with
       | Some status -> ignore (send (Model.SetOutlinerTaskStatus ((Signal.sample row_source).row_uuid, status.uuid)))
       | None -> ())
    | input -> ignore (View_base.handle_outliner_block_content_event input model_source send));
  node

let outliner_row (context : Lui_ui.ui_context) model_source
    retained_row_source row_source send : t =
  let current_row = Signal.sample row_source in
  let search_open = (Signal.sample model_source : Model.logseq_model).search_open in
  let selected_source =
    Signal.map2
      (fun (current : Model.logseq_model) (r : Model.outline_row) ->
        View_base.row_selected_ current r)
      model_source row_source
  in
  if Lui_ui.host context = SwiftUIHost then
    View_base.with_bool_prop_signal Selected selected_source
      (box ~padding:0 ~accessibility_identifier:(reactive View_base.outliner_row_identifier row_source)
        [native_outliner_row model_source retained_row_source row_source send])
  else
  if
    View_base.outliner_row_list_item_press_enabled_
      (Lui_ui.host context) current_row
  then
    View_base.with_bool_prop_signal Selected selected_source
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
            View_base.with_bool_prop_signal Selected selected_source
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
    View_base.with_bool_prop_signal Selected selected_source
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

let outliner_entry context model_source retained_row_source row_source
    send : t =
  column ~padding_horizontal:8
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
        (box ~padding:0
           ~accessibility_identifier_signal:
             (Signal.map2
                (fun (current : Model.logseq_model)
                     (r : Model.outline_row) ->
                  View_base.outliner_journal_button_identifier current r)
                model_source row_source)
           [
             (* Journal section titles align with the bullet column, not
                the block text column: iOS's List leading inset puts both
                at the same x; on Android the outliner row padding already
                insets rows ~8dp, so 9 more puts the title glyph edge at
                the bullet's left edge. *)
             box
               ~padding_horizontal:
                 (if Lui_ui.host context = KotlinHost then 9 else 8)
               ~padding_vertical:12
               [
                 box ~height:14 [];
                 heading ~level:3 ~style_class:"scroll-section-title"
                   ~value_signal:
                     (Signal.map2
                        (fun (current : Model.logseq_model)
                             (r : Model.outline_row) ->
                          View_base.outliner_journal_title current r)
                        model_source row_source)
                   [];
               ];
           ]);
      outliner_row context model_source retained_row_source row_source
        send;
    ]


let toolbar_button icon label identifier action send : t =
  button ~icon ~variant:`ghost ~size:`icon ~width:48 ~height:48
    ~foreground:"muted-foreground" ~label ~accessibility_identifier:identifier
    ~on_press:(fun _ ->
      ignore (send (Model.PerformOutlinerToolbarAction action)))
    []

let outliner_selection_toolbar (context : Lui_ui.ui_context) send : t =
  if Lui_ui.host context = KotlinHost then
    box ~height:56 ~padding_horizontal:8 ~padding_vertical:4
      ~background:"surface-container-high" ~corner_radius:20
      ~accessibility_identifier:"surface.outliner.selection-toolbar"
      [
        toolbar ~orientation:`horizontal ~label:"Outliner selection"
          ~accessibility_identifier:"toolbar.outliner.selection"
          ~style_class:"scroll-leading" ~toolbar_gap:4
          [
            toolbar_button (`app "toolbar-copy") "Copy"
              "button.outliner.selection.copy" "copy" send;
            toolbar_button (`app "toolbar-outdent") "Outdent"
              "button.outliner.selection.outdent" "outdent" send;
            toolbar_button (`app "toolbar-indent") "Indent"
              "button.outliner.selection.indent" "indent" send;
            toolbar_button (`app "toolbar-delete") "Delete"
              "button.outliner.selection.delete" "delete" send;
            toolbar_button (`app "toolbar-copy-reference") "Copy reference"
              "button.outliner.selection.copyReference" "copyReference"
              send;
            toolbar_button (`app "toolbar-copy-url") "Copy URL"
              "button.outliner.selection.copyURL" "copyURL" send;
            toolbar_button (`app "toolbar-unselect") "Unselect"
              "button.outliner.selection.unselect" "unselect" send;
          ];
      ]
  else
    let apple_button icon label identifier action : t =
      button ~icon ~variant:`ghost ~width:58 ~height:46
        ~icon_placement:`top ~label
        ~accessibility_identifier:identifier
        ~on_press:(fun _ ->
          ignore (send (Model.PerformOutlinerToolbarAction action)))
        ~text:label []
    in
    toolbar ~orientation:`horizontal ~label:"Outliner selection"
         ~accessibility_identifier:"toolbar.outliner.selection"
         ~style_class:"scroll-leading leading-inset-12"
         ~toolbar_gap:6 ~placement:"bottom"
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
        button ~icon:(`app "toolbar-unselect") ~variant:`ghost ~width:70
          ~height:46 ~icon_placement:`top ~label:"Unselect"
          ~accessibility_identifier:"button.outliner.selection.unselect"
          ~on_press:(fun _ ->
            ignore
              (send (Model.PerformOutlinerToolbarAction "unselect")))
          ~text:"Unselect" [];
      ]

let outliner_autocomplete_row (context : Lui_ui.ui_context)
    candidate_source send : t =
  let candidate = Signal.sample candidate_source in
  View_base.with_label_signal
    (Signal.map View_base.outliner_autocomplete_label candidate_source)
    (button
       ~text_signal:
         (Signal.map View_base.outliner_autocomplete_label candidate_source)
       ~variant:`ghost
       ~grow:(if Lui_ui.host context = KotlinHost then 0.0 else 1.0)
       ~height:44 ~padding_horizontal:10
       ~background:"autocomplete-row-background" ~foreground:"foreground"
       ~corner_radius:8 ~text_alignment:`start
       ~accessibility_identifier:
         (View_base.outliner_autocomplete_identifier candidate)
       ~on_press:(fun _ ->
         ignore
           (send
              (Model.ChooseOutlinerAutocomplete
                 (Signal.sample candidate_source : Model.outliner_autocomplete_candidate).candidate_value)))
       [])

let outliner_autocomplete_bar (context : Lui_ui.ui_context) model_source
    send : t =
  scroll ~max_height:220
    ~accessibility_identifier:"toolbar.outliner.autocomplete"
    ~style_class:"outliner-autocomplete"
    [
      column ~gap:2 ~padding:8
        ~cross:
          (if Lui_ui.host context = KotlinHost then `stretch else `center)
        ~grow:(if Lui_ui.host context = KotlinHost then 0.0 else 1.0)
        [
          keyed
            ~source:
              (Signal.map
                 View_base.model_outliner_autocomplete_candidates
                 model_source)
            ~key:View_base.outliner_autocomplete_identifier
            ~cmp:compare
            ~mount:(fun candidate_source ->
              outliner_autocomplete_row context candidate_source send);
        ];
    ]

let outliner_editor_toolbar (context : Lui_ui.ui_context) model_source send
    : t =
  if Lui_ui.host context = KotlinHost then
    box ~height:56 ~padding_horizontal:8 ~padding_vertical:4
      ~accessibility_identifier:"surface.outliner.editor-toolbar"
      [
        toolbar ~orientation:`horizontal ~label:"Outliner editor"
          ~accessibility_identifier:"toolbar.outliner.editor"
          ~style_class:"scroll-leading" ~toolbar_gap:4
          [
            View_base.with_label_signal
              (Signal.map View_base.outliner_editor_task_label model_source)
              (button ~icon:(`app "toolbar-task") ~variant:`ghost
                 ~size:`icon ~width:48 ~height:48
                 ~foreground:"muted-foreground"
                 ~accessibility_identifier:"button.outliner.editor.task"
                 ~on_press:(fun _ ->
                   ignore
                     (send
                        (Model.PerformOutlinerToolbarAction "task")))
                 []);
            toolbar_button (`app "toolbar-outdent") "Outdent"
              "button.outliner.editor.outdent" "outdent" send;
            toolbar_button (`app "toolbar-indent") "Indent"
              "button.outliner.editor.indent" "indent" send;
            toolbar_button (`app "toolbar-move-up") "Move up"
              "button.outliner.editor.moveUp" "moveUp" send;
            toolbar_button (`app "toolbar-move-down") "Move down"
              "button.outliner.editor.moveDown" "moveDown" send;
            toolbar_button (`app "toolbar-tag") "Tag"
              "button.outliner.editor.tag" "tag" send;
            toolbar_button (`app "toolbar-camera") "Photo"
              "button.outliner.editor.camera" "camera" send;
            toolbar_button (`app "toolbar-audio") "Record audio"
              "button.outliner.editor.audio" "audio" send;
            toolbar_button (`app "toolbar-attachment") "Upload asset"
              "button.outliner.editor.attachment" "attachment" send;
            button ~variant:`ghost ~size:`icon ~width:48 ~height:48
              ~foreground:"muted-foreground" ~label:"Page reference"
              ~accessibility_identifier:
                "button.outliner.editor.pageReference"
              ~on_press:(fun _ ->
                ignore
                  (send
                     (Model.PerformOutlinerToolbarAction "pageReference")))
              ~text:"[[]]" [];
            toolbar_button (`app "toolbar-hide-keyboard") "Hide keyboard"
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
    toolbar ~orientation:`horizontal ~label:"Outliner editor"
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
          ~label:"Page reference"
          ~accessibility_identifier:"button.outliner.editor.pageReference"
          ~on_press:(fun _ ->
            ignore
              (send
                 (Model.PerformOutlinerToolbarAction "pageReference")))
          ~text:"[[]]" [];
        button ~icon:(`app "toolbar-hide-keyboard") ~variant:`ghost
          ~width:42 ~height:42 ~label:"Hide keyboard"
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
           [ box ~height:10 []; related_row_breadcrumbs row_source send ]);
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
      | View_rows.Reference_heading (key, title) ->
        let identifier =
          if key = "tagged" then "section.tag.tagged-nodes"
          else "section.node.linked-references"
        in
        column ~gap:0 ~padding_horizontal:8
          ~accessibility_identifier:identifier
          [ box ~height:26 []; related_section_heading title; box ~height:8 [] ]
      | View_rows.Empty_tag ->
        box ~padding_horizontal:16
          [ text ~foreground:"muted-foreground" ~value:"No tagged nodes" [] ]
      | View_rows.Reference_row _ ->
        box ~padding_horizontal:8
          [ node_related_row context model_source
              ~source:(reactive View_rows.reference_entry_row entry_source) send ]

let page_loading_view model_source : t =
  if_ ~test:(reactive View_base.page_loading_visible_ model_source)
    (row ~gap:8 ~cross:`center ~padding:16
       ~accessibility_identifier:"status.page-loading"
       [ spinner ~width:16 ~height:16 [];
         text ~foreground:"muted-foreground" ~value:"Loading blocks…" [] ])

let add_first_block_button model_source send : t =
  box ~padding_horizontal:8
    [
      button ~label:"Add first block"
        ~accessibility_identifier:"button.outliner.add-first-block"
        ~on_press:(fun _ ->
          ignore
            (send
               (Model.AddRootBlock
                  (View_base.active_node_page_uuid
                     (Signal.sample model_source)))))
        ~text:"Add first block" [];
    ]

let outliner_entries context model_source ~source send : t =
 fun mount_context parent ->
  let entries = Signal.own_signal mount_context.Lui_ui.ui_scope
    (Signal.map2 View_rows.page_entries source model_source) in
  let first_section = Signal.own_signal mount_context.ui_scope
    (Signal.map View_rows.first_journal_section_count model_source) in
  let section_titles = Signal.own_signal mount_context.ui_scope
    (Signal.map (fun (current : Model.logseq_model) ->
      if View_base.journal_root_visible_ current && current.selected_page = None then
        List.map (fun (marker : Model.journal_section_marker) ->
          marker.start_index, marker.section_title) current.outliner_section_markers
      else []) model_source) in
  let requested = ref [] in
  let on_window entries =
    let ids = List.filter_map View_rows.unloaded_entry_id entries in
    if ids <> !requested then begin
      requested := ids;
      if ids <> [] then ignore (send (Model.EnsureOutlinerRows ids))
    end in
  let scroll_target = Signal.own_signal mount_context.ui_scope
    (Signal.map (fun current -> match View_base.active_node_projection current with
      | Some route -> Option.map (fun uuid -> "outline." ^ uuid) route.Model.node_scroll_target | None -> None) model_source) in
  View_rows.windowed_keyed ~scroll_target ~first_section ~section_titles ~on_window ~is_pinned:View_rows.page_entry_editor_ ~source:entries
    ~key:View_rows.page_entry_identifier ~cmp:compare
    ~mount:(fun entry_source ->
      let render () = match Signal.sample entry_source with
      | View_rows.Outline_entry _ ->
        let retained = Signal.map View_rows.page_entry_outline entry_source in
        outliner_entry context model_source retained
          (Signal.map View_rows.retained_row_value retained) send
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
  column ~accessibility_identifier:"screen.node"
    ~grow:(if Lui_ui.host context = KotlinHost then 1.0 else 0.0)
    [
      virtual_list ~grow:1.0 ~gap:0 ~accessibility_identifier:"list.outliner"
        ~data_attrs_signal:(Signal.map (fun current ->
          ["data-scroll-identity", View_base.outliner_scroll_identity current]) model_source)
        [
          box ~height:16 [];
          if_ ~test:(reactive View_base.active_node_has_breadcrumbs_ model_source)
            (node_breadcrumbs model_source send);
          if_ ~test:(reactive View_base.node_title_visible_ model_source)
            (column ~gap:0
               [ box ~height:26 [];
                 box ~padding_horizontal:16 ~accessibility_identifier:"layout.node.title"
                   [ heading ~level:3 ~value:(reactive View_base.active_node_title model_source)
                       ~accessibility_identifier:"title.node" [] ];
                 box ~height:12 [] ]);
          page_loading_view model_source;
          outliner_entries context model_source
            ~source:(reactive View_rows.retained_outliner_rows model_source) send;
          if_ ~test:(reactive View_base.node_can_add_first_block_ model_source)
            (box ~padding_horizontal:8 [ add_first_block_button model_source send ]);
          box ~height:120 [];
        ];
    ]
