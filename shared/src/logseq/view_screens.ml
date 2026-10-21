open Lui_protocol
open Lui_elements

let search_result_row hit_source send : t =
 fun context parent ->
   let hit = Signal.sample hit_source in
   let elem =
     list_item ~accessibility_identifier:(View_base.search_result_identifier hit)
       ~on_press:(fun _ ->
         ignore
           (send
              (Model.RequestSearchResult
                 (Signal.sample hit_source : Model.search_hit).hit_uuid)))
       [
         column ~gap:4 ~padding_vertical:6 ~grow:1.0
           [
             text
               ~value_signal:(Signal.map View_base.search_result_title
                                hit_source)
               ~style_class:"search-match line-clamp-3"
               ~accessibility_identifier:("search.result.title." ^ hit.hit_uuid)
               [];
             if_
               ~test:
                 (Signal.map View_base.search_result_context_present_
                    hit_source)
               (text
                  ~value_signal:
                    (Signal.map View_base.search_result_breadcrumb
                       hit_source)
                  ~style_class:"caption single-line"
                  ~foreground:"muted-foreground"
                  ~accessibility_identifier:
                    ("search.result.context." ^ hit.hit_uuid)
                  []);
           ];
       ]
   in
   let node = elem context parent in
   if hit.is_page then
     Lui_ui.string_property context node InlineIconName "app:document";
   node

let search_section_heading title identifier : t =
 fun context parent ->
   let title = heading ~level:5 ~accessibility_identifier:identifier ~value:title [] in
   (if Lui_ui.host context = KotlinHost then
      box ~padding_horizontal:20 ~padding_vertical:8 [title]
    else title) context parent

type search_entry = Search_heading of string * string | Search_hit of Model.search_hit

let search_entries current =
  let section label identifier hits = match hits with
    | [] -> [] | _ -> Search_heading (label, identifier) :: List.map (fun hit -> Search_hit hit) hits in
  section "Pages" "search.section.pages" (View_base.page_search_results current)
  @ section "Blocks" "search.section.blocks" (View_base.block_search_results current)

let search_entry_key = function
  | Search_heading (_, identifier) -> identifier
  | Search_hit hit -> View_base.search_result_identifier hit

let search_result_window model_source send : t = fun context parent ->
  let own source = Signal.own_signal context.Lui_ui.ui_scope source in
  let entries = own (Signal.map search_entries model_source) in
  View_rows.windowed_keyed ~identifier:"search.window" ~item_extent:72
    ~reset_key:(own (Signal.map (fun (current : Model.logseq_model) -> current.search_query) model_source))
    ~on_visible_range:(fun _ last ->
      if last >= List.length (Signal.sample entries) - 6 then
        ignore (send Model.LoadMoreSearchResults))
    ~source:entries ~key:search_entry_key ~cmp:compare
    ~mount:(fun entry_source -> match Signal.sample entry_source with
      | Search_heading (title, identifier) -> search_section_heading title identifier
      | Search_hit _ -> fun row_context parent ->
        let hit = Signal.own_signal row_context.Lui_ui.ui_scope
          (Signal.map (function Search_hit hit -> hit | _ -> assert false) entry_source) in
        box ~padding_horizontal:20 [search_result_row hit send] row_context parent) context parent

let search_screen model_source send : t =
  column ~grow:1.0 ~accessibility_identifier:"screen.search"
    [
      row ~height:24 ~gap:6 ~cross:`center ~padding_horizontal:20
        [
          if_
            ~test:(Signal.map View_base.model_search_loading_ model_source)
            (spinner ~width:12 ~height:12
               ~accessibility_identifier:"search.loading" []);
          text
            ~value_signal:
              (Signal.map View_base.search_result_status model_source)
            ~style_class:"caption" ~foreground:"muted-foreground"
            ~accessibility_identifier:"search.status" [];
        ];
      if_
        ~test:(Signal.map View_base.search_empty_state_present_
                 model_source)
        (column ~grow:1.0 ~main:`center ~cross:`center ~gap:10
           ~padding:32
           [
             icon ~name:(`app "search") ~width:48 ~height:48
               ~foreground:"muted-foreground"
               ~accessibility_identifier:"search.empty.icon" [];
             text
               ~value_signal:
                 (Signal.map View_base.search_empty_message model_source)
               ~style_class:"headline" ~text_alignment:`center
               ~accessibility_identifier:"search.empty" [];
             text
               ~value_signal:
                 (Signal.map
                    (fun (model : Model.logseq_model) ->
                      View_base.search_empty_supporting_message
                        (View_base.model_search_query model))
                    model_source)
               ~foreground:"muted-foreground" ~text_alignment:`center
               ~accessibility_identifier:"search.empty.supporting" [];
           ]);
      if_
        ~test:(Signal.map View_base.search_results_present_ model_source)
        (virtual_list ~grow:1.0 ~gap:0
           ~data_attrs_signal:(Signal.map (fun (current : Model.logseq_model) ->
             ["data-scroll-identity", current.search_query]) model_source)
           ~accessibility_identifier:"screen.search.results"
           [search_result_window model_source send]);
    ]

let capture_and_search_row (context : Lui_ui.ui_context) model_source send
    : t =
  if Lui_ui.host context = KotlinHost then
    row ~grow:1.0 ~gap:10 ~cross:`center
      ~accessibility_identifier:"row.bottom.capture"
      [
        View_composer.composer_view context model_source send;
        button ~icon:(`app "search") ~variant:`ghost ~size:`icon ~width:58
          ~height:58 ~background:"glass" ~corner_radius:29 ~label:"Search"
          ~border_width:1 ~border_color:"border"
          ~accessibility_identifier:"button.search"
          ~on_press:(press send Model.OpenSearch)
          [];
      ]
  else
    row ~grow:1.0 ~gap:10 ~cross:`center
      ~accessibility_identifier:"row.bottom.capture"
      [
        View_composer.composer_view context model_source send;
        View_base.with_liquid_glass "circle"
          (button ~icon:(`app "search") ~variant:`ghost ~size:`icon
             ~width:58 ~height:58 ~label:"Search"
             ~accessibility_identifier:"button.search"
             ~on_press:(press send Model.OpenSearch)
             []);
      ]

let main_bottom_chrome (context : Lui_ui.ui_context) model_source send : t
    =
  let selection_chrome : t =
    column ~gap:0 ~padding_horizontal:16
      [
        View_outliner.outliner_selection_toolbar context send;
        box ~height:21 [];
      ]
  in
  if Lui_ui.host context = KotlinHost then
    stack
      [
        if_
          ~test:(Signal.map View_base.bottom_chrome_selection_
                   model_source)
          selection_chrome;
        if_
          ~test:(Signal.map View_base.bottom_chrome_editor_ model_source)
          (column ~gap:0 ~cross:`stretch
             ~background:"surface-container-low" ~corner_radius:20
             ~accessibility_identifier:"container.outliner.editor-chrome"
             [
               if_
                 ~test:
                   (Signal.map View_base.outliner_autocomplete_active_
                      model_source)
                 (View_outliner.outliner_autocomplete_bar context model_source
                    send);
               View_outliner.outliner_editor_toolbar context model_source send;
             ]);
        if_
          ~test:
            (Signal.map View_base.bottom_chrome_expanded_composer_
               model_source)
          (column ~gap:0 ~padding_horizontal:16
             [
               box ~height:6 [];
               row ~cross:`center
                 ~accessibility_identifier:"row.composer.placement"
                 [ View_composer.composer_view context model_source send ];
               box ~height:21 [];
             ]);
        if_
          ~test:
            (Signal.map View_base.bottom_chrome_capture_and_search_
               model_source)
          (column ~gap:0 ~padding_horizontal:16
             [
               box ~height:8 [];
               capture_and_search_row context model_source send;
               box ~height:21 [];
             ]);
      ]
  else
    stack
      [
        if_
          ~test:(Signal.map View_base.bottom_chrome_selection_
                   model_source)
          (column ~gap:0 ~padding_horizontal:16 [ box ~height:21 [] ]);
        if_
          ~test:(Signal.map View_base.bottom_chrome_editor_ model_source)
          (View_base.with_liquid_glass "container"
             (column ~gap:0 ~padding_horizontal:8 ~padding_vertical:4
                [
                  if_
                    ~test:(Signal.map View_base.outliner_autocomplete_active_
                             model_source)
                    (View_outliner.outliner_autocomplete_bar context
                       model_source send);
                  View_outliner.outliner_editor_toolbar context model_source
                    send;
                ]));
        if_
          ~test:
            (Signal.map View_base.bottom_chrome_expanded_composer_
               model_source)
          (column ~container_relative_frame:`horizontal ~cross:`stretch
             ~gap:0 ~padding_horizontal:16
             [
               box ~height:6 [];
               row ~cross:`center
                 ~accessibility_identifier:"row.composer.placement"
                 [ View_composer.composer_view context model_source send ];
               box ~height:21 [];
             ]);
        if_
          ~test:
            (Signal.map View_base.bottom_chrome_capture_and_search_
               model_source)
          (column ~container_relative_frame:`horizontal ~cross:`stretch
             ~gap:0 ~padding_horizontal:16
             [
               box ~height:8 [];
               capture_and_search_row context model_source send;
               box ~height:21 [];
             ]);
      ]

let root_outliner_view (context : Lui_ui.ui_context) model_source visible_source
    send : t =
  box ~grow:1.0 ~accessibility_identifier:"layout.outliner.horizontal-inset"
    [
      (* Each graph owns a fresh native scroll view and virtual window. *)
      keyed
        ~source:(Signal.map (fun (current : Model.logseq_model) ->
          [Option.value ~default:"local" current.selected_graph_id]) model_source)
        ~key:Fun.id ~cmp:String.compare
        ~mount:(fun _ -> View_base.with_selected_signal visible_source
        (virtual_list ~grow:1.0
           ~data_attrs_signal:(Signal.map (fun current ->
             ["data-scroll-identity", View_base.outliner_scroll_identity current]) model_source)
           ~style_class:"retained-pane scroll-section-titles"
           ~accessibility_identifier:"list.outliner"
        [
          box ~height:16 ~accessibility_identifier:"spacer.outliner.top" [];
          if_
            ~test:
              (Signal.map View_base.selected_page_content_title_visible_
                 model_source)
            (column ~gap:0
               [
                 box ~padding_horizontal:16
                   ~accessibility_identifier:"layout.selected-page.title"
                   [
                     heading ~level:3
                       ~value_signal:
                         (Signal.map View_base.selected_page_title
                            model_source)
                       ~accessibility_identifier:"title.selected-page" [];
                   ];
                 box ~height:12 [];
               ]);
          View_outliner.outliner_entries context model_source
            ~source:
              (Signal.map View_rows.retained_outliner_rows
                 model_source)
            send;
          (* The virtual list retains positional slots. A keyed child inside
             a stable container renews appearance even for short journals. *)
          box ~padding:0
            [ keyed
                ~source:(Signal.map (fun (current : Model.logseq_model) ->
                  if View_base.older_journals_visible_ current then
                    [Option.value ~default:"local" current.selected_graph_id]
                  else []) model_source)
                ~key:Fun.id ~cmp:String.compare
                ~mount:(fun _ ->
                  box ~height:1
                    ~accessibility_identifier:"outliner.load-older-sentinel"
                    ~on_appear:(fun _ ->
                      ignore (send Model.LoadOlderJournals))
                    []);
            ];
          View_outliner.page_loading_view model_source;
          if_
            ~test:(Signal.map View_base.main_can_add_first_block_
                     model_source)
            (box ~padding_horizontal:8
               [ View_outliner.add_first_block_button model_source send ]);
          box ~height:120 [];
          ]));
    ]

let retained_journal_pane (context : Lui_ui.ui_context) model_source send
    : t =
    box ~grow:1.0 ~accessibility_identifier:"pane.journals"
      [
        root_outliner_view context
          (Signal.map View_base.journal_navigation_model model_source)
          (Signal.map
             (fun (current : Model.logseq_model) ->
               View_base.journal_home_visible_
                 { current with
                   Model.node_routes = [];
                   app_navigation_path = [];
                   search_open = false;
                   search_navigation_path = [];
                 })
             model_source)
          send;
      ]

let journal_tree_panes (context : Lui_ui.ui_context) model_source send : t
    =
  if Lui_ui.host context = KotlinHost then
    stack ~grow:1.0
      [
        retained_journal_pane context model_source send;
        keyed
          ~source:(Signal.map View_base.selected_page_models model_source)
          ~key:View_base.selected_page_model_key ~cmp:compare
          ~mount:(fun selected_model_source ->
            box ~grow:1.0 ~accessibility_identifier:"pane.selected-page"
              [
                root_outliner_view context selected_model_source
                  (Signal.map View_base.selected_page_visible_
                     selected_model_source)
                  send;
              ]);
      ]
  else
    stack ~grow:1.0
      [
        keyed
          ~source:(Signal.map View_base.selected_page_models model_source)
          ~key:View_base.selected_page_model_key ~cmp:compare
          ~mount:(fun selected_model_source ->
            box ~grow:1.0 ~accessibility_identifier:"pane.selected-page"
              [
                root_outliner_view context selected_model_source
                  (Signal.map View_base.selected_page_visible_
                     selected_model_source)
                  send;
              ]);
        retained_journal_pane context model_source send;
      ]

let global_effect_error_feedback (context : Lui_ui.ui_context)
    model_source : t =
  if Lui_ui.host context = KotlinHost then
    alert ~variant:`destructive ~padding:14 ~corner_radius:16
      ~border_width:0
      ~accessibility_identifier:"layout.error.banner"
      [
        row ~gap:10 ~cross:`center
          [
            icon ~name:(`app "warning") ~width:22 ~height:22
              ~foreground:"destructive" [];
            text
              ~value_signal:
                (Signal.map View_base.effect_error_message model_source)
              ~grow:1.0 ~accessibility_identifier:"error.banner" [];
          ];
      ]
  else
    box ~padding_horizontal:16 ~padding_vertical:8
      [
        alert ~variant:`destructive ~padding:14 ~corner_radius:16
          ~border_width:0
          ~accessibility_identifier:"layout.error.banner"
          [
            row ~gap:10 ~cross:`center
              [
                icon ~name:(`app "warning") ~width:22 ~height:22
                  ~foreground:"destructive" [];
                text
                  ~value_signal:
                    (Signal.map View_base.effect_error_message
                       model_source)
                  ~grow:1.0 ~accessibility_identifier:"error.banner"
                  [];
              ];
          ];
      ]

let graph_loading_feedback (context : Lui_ui.ui_context) model_source : t
    =
  if Lui_ui.host context = KotlinHost then
    column ~grow:1.0 ~main:`center ~cross:`center ~gap:12
      ~background:"background"
      ~accessibility_identifier:"journals.loading"
      [
        spinner ~accessibility_identifier:"spinner.graph-loading" [];
        text
          ~value_signal:
            (Signal.map View_base.graph_loading_message model_source)
          ~foreground:"muted-foreground" [];
      ]
  else
    column ~accessibility_identifier:"journals.loading"
      [
        text
          ~value_signal:
            (Signal.map View_base.graph_loading_message model_source)
          [];
      ]

let logseq_main_view (context : Lui_ui.ui_context) model_source send : t
    =
  stack ~grow:1.0
    [
      if_
        ~test:(Signal.map View_base.journal_tree_retained_ model_source)
        (journal_tree_panes context model_source send);
      if_
        ~test:(Signal.map View_base.flashcards_destination_ model_source)
        (View_flashcards.flashcard_screen model_source send);
      if_
        ~test:(Signal.map View_base.graphs_destination_ model_source)
        (View_graphs.graphs_screen context model_source send);
      if_
        ~test:(Signal.map View_base.global_effect_error_present_
                 model_source)
        (global_effect_error_feedback context model_source);
      if_
        ~test:(Signal.map View_base.graph_loading_visible_ model_source)
        (graph_loading_feedback context model_source);
      if_
        ~test:(Signal.map View_base.journal_root_visible_ model_source)
        (text ~accessibility_identifier:"journals.graph-loaded" ~value:"" []);
    ]

let main_header_model context current =
  if Lui_ui.host context = KotlinHost then current
  else View_base.navigation_root_model current

let main_header_leading_content (context : Lui_ui.ui_context)
    ~source:model_source send : t =
  stack
    [
      if_
        ~test:
          (Signal.map
             (fun (current : Model.logseq_model) ->
               Lui_ui.host context = KotlinHost
               && View_base.node_screen_visible_ current)
             model_source)
        (button ~icon:(`app "navigation-back") ~variant:`ghost ~size:`icon
           ~label:"Back"
           ~accessibility_identifier:"button.navigation.back"
           ~on_press:(fun _ ->
             ignore (send (Model.BackAppNavigation 1)))
           []);
      if_
        ~test:
          (Signal.map View_base.primary_sidebar_button_visible_
             model_source)
        (button ~icon:(`app "sidebar-toggle") ~variant:`ghost ~size:`icon
           ~width:44 ~height:44
           ~label:"Toggle sidebar"
           ~style_class:"drawer-toggle"
           ~accessibility_identifier:"button.sidebar"
           ~disabled_signal:
             (Signal.map View_base.sidebar_drag_disabled_ model_source)
           ~on_press:(fun _ ->
             ignore
               (send
                  (if (Signal.sample model_source).Model.sidebar_open
                   then Model.CloseSidebar
                   else Model.OpenSidebar)))
           []);
    ]

let main_header_leading context model_source send =
  main_header_leading_content context
    ~source:(reactive (main_header_model context) model_source) send

let main_header_title (context : Lui_ui.ui_context) model_source : t =
  text
    ~value:
      (reactive
         (fun current ->
           View_base.main_title (main_header_model context current))
         model_source)
    ~style_class:"headline navigation-title" ~accessibility_identifier:"title.main" []

let main_header_sync (context : Lui_ui.ui_context) model_source send : t =
  stack
    [
      if_
        ~test:
          (Signal.map View_base.connection_control_visible_ model_source)
        (View_base.with_label_signal
           (Signal.map View_base.sync_indicator_label model_source)
           (button
              ~icon:(`app "status-dot")
              ~variant:`ghost ~size:`icon
              ~foreground_signal:
                (Signal.map View_base.sync_indicator_foreground
                   model_source)
              ~accessibility_identifier_signal:
                (Signal.map View_base.sync_accessibility_identifier
                   model_source)
              ~on_press:(press send Model.OpenSyncDetails)
              []));
    ]

let active_overflow_menu model_source send : t =
 fun context parent ->
   let page_actions_source =
     Signal.map View_base.active_page_actions_visible_ model_source
   in
   let settings_source =
     Signal.map View_base.connection_settings_visible_ model_source
   in
   let kotlin_host = Lui_ui.host context = KotlinHost in
   (* iOS menu items carry no icons; the Kotlin popup did. *)
   let item_icon name = if kotlin_host then Some (`app name) else None in
   let entries =
     [ if_ ~test:page_actions_source
         (if kotlin_host then
            menu_item
              ~text_signal:
                (Signal.map View_base.active_page_favorite_label model_source)
              ~icon_signal:
                (Signal.map
                   (fun current ->
                     `app
                       (if View_base.active_page_favorite_label current
                           = "Unfavorite"
                        then "star-filled"
                        else "star"))
                   model_source)
              ~on_press:(press send Model.ToggleActivePageFavorite)
              []
          else
            menu_item
              ~text_signal:
                (Signal.map View_base.active_page_favorite_label model_source)
              ~on_press:(press send Model.ToggleActivePageFavorite)
              []);
       if_ ~test:page_actions_source
         (menu_item ~text:"Share" ?icon:(item_icon "share")
            ~on_press:(press send Model.ShareActivePage)
            []);
       if_ ~test:page_actions_source
         (menu_item ~text:"Delete" ~variant:`destructive
            ?icon:(item_icon "toolbar-delete")
            ~on_press:(press send Model.RequestDeleteActivePage)
            []);
       if_ ~test:settings_source
         (menu_item ~text:"Settings" ?icon:(item_icon "settings")
            ~on_press:(press send Model.OpenSettings)
            []);
     ]
   in
   if kotlin_host then
     menu ~icon:(`app "more-vert") ~label:"More"
       ~accessibility_identifier:"button.overflow-menu" entries context parent
   else
     box ~width:44 ~height:44
       [ menu ~icon:(`app "more-horiz") ~style_class:"capsule" ~label:"More"
           ~accessibility_identifier:"button.connection" entries ]
       context parent

let main_header_connection model_source send : t =
  stack
    [
      if_
        ~test:
          (Signal.map View_base.connection_control_visible_ model_source)
        (fun context parent ->
          (stack [
               if_ ~test:(Signal.map View_base.connection_settings_visible_ model_source)
                 (button ~icon:(`app "calendar") ~label:"Go to journal"
                    ~variant:`ghost ~size:`icon ~width:44 ~height:44
                    ~accessibility_identifier:"button.journal-calendar"
                    ~on_press:(press send Model.OpenJournalCalendar) []);
               if_ ~test:(Signal.map View_base.active_page_actions_visible_ model_source)
                 (active_overflow_menu model_source send) ] context parent));
    ]

let native_node_destination ~source:title_source content : t =
 fun context parent ->
   let node = Lui_ui.platform_tweak context "native-navigation-title" in
   Lui_ui.extension_property_signal context node "title" title_source;
   ignore (content context (Some node));
   attach context parent node;
   node

let native_node_screen (context : Lui_ui.ui_context) model_source
    ~source:route_source send : t =
  let route_model_source =
    Signal.map2 View_base.node_route_model model_source route_source
  in
  if Lui_ui.host context = KotlinHost then
    box ~grow:1.0 ~background:"background"
      [ View_outliner.node_screen context route_model_source send ]
  else
    native_node_destination
      ~source:
        (reactive
           (fun (route : Model.node_projection) ->
             StringValue route.node_title)
           route_source)
      (View_outliner.node_screen context route_model_source send)

let native_node_stack context model_source ~source:routes_source send =
  keyed
    ~source:
      (reactive
         (fun routes -> List.mapi (fun index route -> (index, route)) routes)
         routes_source)
    ~key:(fun (index, (route : Model.node_projection)) ->
      (index, route.node_uuid))
    ~cmp:compare
    ~mount:(fun visit_source ->
      native_node_screen context model_source
        ~source:(reactive (fun (_, route) -> route) visit_source) send)

let native_search_view (_context : Lui_ui.ui_context) model_source send :
    t =
 fun context parent ->
   let node = Lui_ui.extension context "native-search-presentation" in
   attach context parent node;
   let presented_source =
     Signal.map View_base.model_search_open_ model_source
   in
   let depth_source =
     Signal.map View_base.search_navigation_depth model_source
   in
   let query_source = Signal.map View_base.model_search_query model_source in
   Lui_ui.extension_property_signal context node "presented"
     (Signal.map View_base.bool_wire_value presented_source);
   Lui_ui.extension_property_signal context node "depth"
     (Signal.map View_base.int_wire_value depth_source);
   Lui_ui.extension_property_signal context node "query"
     (Signal.map View_base.string_wire_value query_source);
   Lui_ui.extension_property context node "title" (StringValue "Search");
   Lui_ui.on_event context node (fun input_event ->
       ignore (View_base.handle_native_search_event input_event send));
   if Lui_ui.host context = KotlinHost then
     let _ =
       stack ~grow:1.0
         [
           column ~grow:1.0
             ~display_signal:(Signal.map (fun current ->
               if View_base.kotlin_app_root_visible_ current then `contents else `none) model_source)
             [logseq_main_view context (Signal.map View_base.navigation_root_model model_source) send];
           column ~grow:1.0
             ~display_signal:(Signal.map (fun (current : Model.logseq_model) ->
               if current.search_open then `none else `contents) model_source)
             [native_node_stack context model_source
               ~source:(Signal.map Model.app_node_routes model_source) send];
           if_
             ~test:
               (Signal.map View_base.kotlin_search_root_visible_
                  model_source)
             (column ~grow:1.0 ~background:"background"
                [ search_screen model_source send ]);
           native_node_stack context model_source
             ~source:(Signal.map View_base.search_node_routes model_source) send;
         ]
         context (Some node)
     in
     node
   else (
     ignore
       ((logseq_main_view context (Signal.map View_base.navigation_root_model model_source) send) context (Some node));
     ignore
       ((column ~grow:1.0 [ search_screen model_source send ]) context
          (Some node));
     ignore
       ((native_node_stack context model_source
           ~source:(reactive View_base.search_node_routes model_source) send)
          context (Some node));
     node)

let native_navigation_view (_context : Lui_ui.ui_context) model_source send
    : t =
 fun context parent ->
   let node = Lui_ui.extension context "native-navigation-stack" in
   attach context parent node;
   let depth_source =
     Signal.map View_base.app_navigation_depth model_source
   in
   let back_depth_source =
     Signal.map View_base.app_back_depth model_source
   in
   let bottom_occupies_source =
     Signal.map View_base.bottom_chrome_occupies_layout_space_
       model_source
   in
   let composer_dismissal_source =
     Signal.map View_base.bottom_chrome_expanded_composer_ model_source
   in
   let title_source =
     Signal.map
       (fun current -> View_base.main_title (main_header_model context current))
       model_source
   in
   Lui_ui.extension_property_signal context node "depth"
     (Signal.map View_base.int_wire_value depth_source);
   Lui_ui.extension_property_signal context node "back-depth"
     (Signal.map View_base.int_wire_value back_depth_source);
   Lui_ui.extension_property_signal context node
     "bottom-occupies-layout-space"
     (Signal.map View_base.bool_wire_value bottom_occupies_source);
   Lui_ui.extension_property_signal context node
     "composer-dismissal-enabled"
     (Signal.map View_base.bool_wire_value composer_dismissal_source);
   Lui_ui.extension_property_signal context node "title"
     (Signal.map View_base.string_wire_value title_source);
   Lui_ui.on_event context node (fun input_event ->
       ignore
         (View_base.handle_native_navigation_event input_event send));
   if Lui_ui.host context = KotlinHost then (
     (* Two extension children: [content, bottom chrome]. The host hoists
        the second child to a bottom inset/overlay (mirroring the iOS
        bottomChromeIndex); inside the content column its internal `grow`
        props would starve the weighted journal content. *)
     ignore
       ((stack ~grow:1.0
           [
             column ~grow:1.0
               [
                 if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> not current.search_open) model_source)
                 (row ~cross:`center ~gap:8 ~height:64 ~padding_horizontal:16
                   ~accessibility_identifier:"header.main"
                   [
                     column ~width:44 ~height:44 ~corner_radius:22
                       ~background:"glass" ~main:`center ~cross:`center
                       [ main_header_leading context model_source send ];
                     main_header_title context model_source;
                     spacer ~grow:1.0 [];
                     box ~corner_radius:22 ~background:"glass"
                       ~padding_horizontal:6
                       [
                         row ~cross:`center ~gap:4
                           [
                             main_header_sync context model_source send;
                             main_header_connection model_source send;
                           ];
                       ];
                   ]);
                 stack ~grow:1.0
                   [ native_search_view context model_source send ];
               ];
             if_
               ~test:(Signal.map View_base.asset_preview_ model_source)
               (file_preview
                  ~path_signal:
                    (Signal.map View_base.asset_preview_path model_source)
                  ~on_dismiss:(press send Model.DismissAssetPreview)
                  []);
           ])
          context (Some node));
     ignore
       ((main_bottom_chrome context model_source send) context (Some node));
     node)
   else (
     ignore
       ((column
           [
             native_search_view context model_source send;
             if_
               ~test:(Signal.map View_base.bottom_chrome_selection_
                        model_source)
               (View_outliner.outliner_selection_toolbar context send);
           ])
          context (Some node));
     ignore
       ((main_header_leading context model_source send) context
          (Some node));
     ignore ((main_header_title context model_source) context (Some node));
     ignore
       ((main_header_sync context model_source send) context (Some node));
     ignore
       ((main_header_connection model_source send) context (Some node));
     ignore
       ((main_bottom_chrome context model_source send) context (Some node));
     ignore
       ((native_node_stack context model_source
           ~source:(reactive Model.app_node_routes model_source) send)
          context (Some node));
     ignore
       ((if_
           ~test:(Signal.map View_base.asset_preview_ model_source)
           (file_preview
              ~path_signal:
                (Signal.map View_base.asset_preview_path model_source)
              ~on_dismiss:(press send Model.DismissAssetPreview)
              []))
          context (Some node));
     node)

let authentication_content (context : Lui_ui.ui_context) model_source
    send : t =
  column ~cross:`center ~gap:0 ~max_width:400
    [
      row ~width:96 ~height:96 ~corner_radius:22
        [
          (if Lui_ui.host context = KotlinHost then
             (* Android icon resolution is vector-only, so the product
                logo rides the shared image-id channel instead; the host
                registers logseq_logo under this id at startup. *)
             image ~image:1 ~width:96 ~height:96 ~alt:"Logseq" []
           else
             icon ~name:(`app "logo") ~width:96 ~height:96 []);
        ];
      box ~height:28 [];
      heading ~level:1 ~value:"Logseq" [];
      box ~height:10 [];
      text ~foreground:"muted-foreground" ~text_alignment:`center
        ~value:"Capture, sync, and review your notes anywhere." [];
      box ~height:36 [];
      button ~accessibility_identifier:"button.hosted-sign-in"
        ~variant:`primary ~size:`lg ~grow:1.0 ~text_alignment:`center
        ~disabled_signal:
          (Signal.map View_base.authentication_signing_in_ model_source)
        ~on_press:(press send Model.SignIn)
        ~text:"Sign in" [];
      if_
        ~test:
          (Signal.map View_base.authentication_error_present_
             model_source)
        (column ~cross:`center
           [
             box ~height:16 [];
             text
               ~value_signal:
                 (Signal.map View_base.authentication_error_message
                    model_source)
               ~style_class:"caption" ~foreground:"destructive"
               ~text_alignment:`center
               ~accessibility_identifier:"text.authentication-error" [];
           ]);
    ]

let authentication_screen (context : Lui_ui.ui_context) model_source send
    : t =
  if Lui_ui.host context = KotlinHost then
    column ~accessibility_identifier:"screen.authentication" ~grow:1.0
      ~main:`center ~cross:`stretch ~padding:32
      [ authentication_content context model_source send ]
  else
    column ~accessibility_identifier:"screen.authentication" ~grow:1.0
      ~container_relative_frame:`vertical ~main:`center ~cross:`center
      ~padding:32
      [ authentication_content context model_source send ]

let application_main_content (context : Lui_ui.ui_context) model_source
    send : t =
  let content_children : t list =
    if Lui_ui.platform context = AndroidOS then
      [
        if_
          ~test:(Signal.map View_base.main_screen_visible_ model_source)
          (native_navigation_view context model_source send);
        if_
          ~test:
            (Signal.map View_base.graph_picker_screen_visible_
               model_source)
          (View_graphs.graph_picker_screen context model_source send);
        if_
          ~test:(Signal.map View_base.model_settings_open_ model_source)
          (View_settings.settings_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.model_create_graph_open_
                   model_source)
          (View_graphs.graph_create_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.graph_deletion_pending_
                   model_source)
          (View_graphs.graph_delete_dialog context model_source send);
        if_
          ~test:(Signal.map View_base.model_graph_password_open_
                   model_source)
          (View_graphs.graph_password_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.page_deletion_pending_ model_source)
          (View_settings.page_delete_dialog context send);
        if_
          ~test:(Signal.map View_base.sign_out_pending_ model_source)
          (View_settings.sign_out_dialog context send);
        if_
          ~test:(Signal.map View_base.model_sync_details_open_
                   model_source)
          (View_settings.sync_status_sheet context model_source send);
      ]
    else
      [
        if_
          ~test:(Signal.map View_base.main_screen_visible_ model_source)
          (native_navigation_view context model_source send);
        if_
          ~test:
            (Signal.map View_base.graph_picker_screen_visible_
               model_source)
          (View_graphs.graph_picker_screen context model_source send);
        if_
          ~test:
            (Signal.map View_base.authentication_screen_visible_
               model_source)
          (authentication_screen context model_source send);
        if_
          ~test:(Signal.map View_base.model_settings_open_ model_source)
          (View_settings.settings_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.model_create_graph_open_
                   model_source)
          (View_graphs.graph_create_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.graph_deletion_pending_
                   model_source)
          (View_graphs.graph_delete_dialog context model_source send);
        if_
          ~test:(Signal.map View_base.model_graph_password_open_
                   model_source)
          (View_graphs.graph_password_sheet context model_source send);
        if_
          ~test:(Signal.map View_base.page_deletion_pending_ model_source)
          (View_settings.page_delete_dialog context send);
        if_
          ~test:(Signal.map View_base.sign_out_pending_ model_source)
          (View_settings.sign_out_dialog context send);
        if_
          ~test:(Signal.map View_base.model_sync_details_open_
                   model_source)
          (View_settings.sync_status_sheet context model_source send);
      ]
  in
  let stack_grow = Lui_ui.platform context = AndroidOS in
  let confirmation = keyed
      ~source:(Signal.map (fun (current : Model.logseq_model) ->
        Option.to_list current.capture_confirmation) model_source)
      ~key:string_of_int ~cmp:compare
      ~mount:(fun id_source ->
        let notification = toast ~duration:2500 ~label:"Added to today" ~margin_top:8
          ~on_dismiss:(press send (Model.DismissCaptureConfirmation (Signal.sample id_source)))
          [text ~value:"✅" ~accessibility_identifier:"capture.confirmation.icon" [];
           text ~value:"Added to today" ~accessibility_identifier:"capture.confirmation" []] in
        if Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost then
          box [(fun context parent ->
            let node = Lui_ui.extension context "native-top-notification" in
            attach context parent node;
            ignore (notification context (Some node));
            node)]
        else notification) in
  let content = if stack_grow then
    if Lui_ui.host context = KotlinHost then
      stack ~grow:1.0 content_children
    else
      stack ~grow:1.0 ~container_relative_frame:`vertical
        content_children
  else stack content_children in
  overlay ~alignment:`top ~accessibility_identifier:"capture.confirmation.overlay"
    [content; confirmation]

let logseq_view (context : Lui_ui.ui_context) model_source send : t =
  let drawer_main = application_main_content context model_source send in
  let drawer_panel = View_sidebar.sidebar_view context model_source send in
  if Lui_ui.platform context = AndroidOS then
    if Lui_ui.host context = KotlinHost then
      stack ~grow:1.0
        [
          if_
            ~test:
              (Signal.map View_base.authentication_screen_visible_
                 model_source)
            (authentication_screen context model_source send);
          if_
            ~test:
              (Signal.map View_base.application_shell_visible_
                 model_source)
            (drawer
               ~selected_signal:
                 (Signal.map View_base.drawer_selected_ model_source)
               ~disabled_signal:
                 (Signal.map View_base.drawer_disabled_ model_source)
               ~width:320 ~label:"Navigation"
               ~accessibility_identifier:"application.shell"
               ~on_toggle:(fun input_event ->
                 match input_event with
                 | ToggleChanged (_node, open_) ->
                   ignore
                     (send
                        (if open_ then Model.OpenSidebar
                         else Model.CloseSidebar))
                 | _ -> ())
               drawer_main drawer_panel);
        ]
    else
      stack ~grow:1.0 ~container_relative_frame:`both
        [
          if_
            ~test:
              (Signal.map View_base.authentication_screen_visible_
                 model_source)
            (authentication_screen context model_source send);
          if_
            ~test:
              (Signal.map View_base.application_shell_visible_
                 model_source)
            (drawer
               ~selected_signal:
                 (Signal.map View_base.drawer_selected_ model_source)
               ~disabled_signal:
                 (Signal.map View_base.drawer_disabled_ model_source)
               ~width:360 ~label:"Navigation"
               ~accessibility_identifier:"application.shell"
               ~on_toggle:(fun input_event ->
                 match input_event with
                 | ToggleChanged (_node, open_) ->
                   ignore
                     (send
                        (if open_ then Model.OpenSidebar
                         else Model.CloseSidebar))
                 | _ -> ())
               drawer_main drawer_panel);
        ]
  else
    drawer
      ~selected_signal:
        (Signal.map View_base.drawer_selected_ model_source)
      ~disabled_signal:
        (Signal.map View_base.drawer_disabled_ model_source)
      ~width:360 ~label:"Navigation"
      ~accessibility_identifier:"application.shell"
      ~on_toggle:(fun input_event ->
        match input_event with
        | ToggleChanged (_node, open_) ->
          ignore
            (send
               (if open_ then Model.OpenSidebar else Model.CloseSidebar))
        | _ -> ())
      drawer_main drawer_panel
