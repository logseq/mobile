open Lui_protocol
open Lui_elements

let search_result_row model_source hit_source send : t =
 custom @@ fun context parent ->
   let hit : Model.search_hit = Signal.sample hit_source in
   let native_list = Lui_ui.host context = SwiftUIHost in
   let elem =
     list_item ~separator:`hidden
       ?padding_horizontal:(if native_list then Some 16 else None)
       ?padding_vertical:(if native_list then Some (if hit.is_page then 3 else 5) else None)
       ~accessibility_identifier:(View_base.search_result_identifier hit)
       ~on_press:(fun _ ->
         ignore
           (send
              (Model.RequestSearchResult
                 (Signal.sample hit_source : Model.search_hit).hit_uuid)))
       [
         column ~gap:4 ~padding_vertical:3 ~grow:1.0
           ?min_height:(if native_list then Some 44 else None)
           [
             if_
               ~test:
                 (Signal.map View_base.search_result_context_present_
                    hit_source)
               (text
                  ~value:
                    (reactive (Signal.map2 View_base.search_result_breadcrumb model_source hit_source))
                  ~style_class:"caption single-line"
                  ~foreground:"muted-foreground"
                  ~accessibility_identifier:
                    ("search.result.context." ^ hit.hit_uuid)
                  []);
             text
               ~value:(reactive (Signal.map2 View_base.search_result_title model_source hit_source))
               ~style_class:"search-match line-clamp-3"
               ~accessibility_identifier:("search.result.title." ^ hit.hit_uuid)
               [];
           ];
       ]
   in
   let node = mount context ?parent elem in
   if hit.is_page then
     Lui_ui.string_property context node InlineIconName "app:document";
   node

let search_section_heading title identifier : t =
 custom @@ fun context parent ->
   let title = heading ~level:`h5 ~foreground:"muted-foreground"
     ~accessibility_identifier:identifier ~value:title [] in
   mount context ?parent (if Lui_ui.host context = KotlinHost then
      box ~padding_horizontal:20 ~padding_vertical:5 [title]
    else list_item ~separator:`hidden ~padding_horizontal:16 ~padding_vertical:7 [title])

type search_entry = Search_heading of string * string | Search_hit of Model.search_hit

let search_entries current =
  let section label identifier hits = match hits with
    | [] -> [] | _ -> Search_heading (label, identifier) :: List.map (fun hit -> Search_hit hit) hits in
  section "Pages" "search.section.pages" (View_base.page_search_results current)
  @ section "Blocks" "search.section.blocks" (View_base.block_search_results current)

let search_entry_key = function
  | Search_heading (_, identifier) -> identifier
  | Search_hit hit -> View_base.search_result_identifier hit

let mount_search_entry model_source send entry_source =
  match Signal.sample entry_source with
      | Search_heading (title, identifier) -> search_section_heading title identifier
      | Search_hit _ -> custom @@ fun context parent ->
        let hit = Signal.own_signal context.Lui_ui.ui_scope
          (Signal.map (function Search_hit hit -> hit | _ -> assert false) entry_source) in
        mount context ?parent (search_result_row model_source hit send)

let search_result_entries model_source send : t =
  keyed ~source:(reactive search_entries model_source)
    ~key:search_entry_key ~cmp:compare ~mount:(mount_search_entry model_source send)

let search_result_list model_source send : t =
 custom @@ fun context parent ->
  let load_more last =
    let current = Signal.sample model_source in
    if last >= current.Model.search_result_count - 6 then
      ignore (send Model.LoadMoreSearchResults) in
  mount context ?parent (if Lui_ui.host context = KotlinHost then
     let count = Signal.own_signal context.Lui_ui.ui_scope
       (Signal.map (fun current -> List.length (search_entries current)) model_source) in
     let offset = Signal.own_signal context.Lui_ui.ui_scope
       (Signal.map (fun _ -> 0) model_source) in
     virtual_list ~grow:1.0 ~accessibility_identifier:"screen.search.results" [
       View_rows.paged_keyed ~identifier:"search.results.window" ~item_extent:72
         ~count ~offset
         ~on_visible_range:(fun _ last -> load_more last)
         ~source:(reactive search_entries model_source)
         ~key:search_entry_key ~cmp:compare ~mount:(mount_search_entry model_source send)]
   else
     list ~grow:1.0 ~style:`plain ~track_visible_range:true
       ~accessibility_identifier:"screen.search.results"
       ~on_visible_range:(function
         | Range { last; _ } -> load_more last
         | _ -> ())
       [search_result_entries model_source send])

let search_screen model_source send : t =
  column ~grow:1.0 ~accessibility_identifier:"screen.search"
    [
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
               ~value:
                 (reactive View_base.search_empty_message model_source)
               ~style_class:"headline" ~text_alignment:`center
               ~accessibility_identifier:"search.empty" [];
             text
               ~value:
                 (reactive (Signal.map
                    (fun (model : Model.logseq_model) ->
                      View_base.search_empty_supporting_message
                        (View_base.model_search_query model))
                    model_source))
               ~foreground:"muted-foreground" ~text_alignment:`center
               ~accessibility_identifier:"search.empty.supporting" [];
           ]);
      if_
        ~test:(Signal.map View_base.search_results_present_ model_source)
        (search_result_list model_source send);
    ]

let uses_ios_native_header context =
  Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost

let bottom_tab_row ~show_flashcards model_source send : t =
  let current = Signal.sample model_source in
  let cell = 50 and tab_width = 58 and inset = 4 in
  let destinations = [
    Model.JournalsDestination, "Home", "home", "tab-home", "tab-home-selected", Model.ShowJournals;
    Model.TasksDestination, "Tasks", "tasks", "tab-tasks", "tab-tasks-selected", Model.ShowTasks;
  ] @ (if show_flashcards then
    [Model.FlashcardsDestination, "Flashcards", "flashcards", "flashcards", "flashcards", Model.ShowFlashcards]
    else []) in
  let navigate destination action =
    let current : Model.logseq_model = Signal.sample model_source in
    if current.destination <> destination || current.app_navigation_path <> []
       || (destination = Model.JournalsDestination && current.selected_page <> None)
    then ignore (send action) in
  let tab (destination, title, name, image, selected_image, action) =
    let selected = Signal.map (fun (current : Model.logseq_model) -> current.destination = destination) model_source in
    icon_button ~icon:(`app image)
      ~icon_signal:(Signal.map (fun selected -> `app (if selected then selected_image else image)) selected)
      ~selected_signal:selected ~variant:`ghost ~size:`icon ~width:tab_width ~height:cell
      ~style_class:"system-toolbar-icon"
      ~foreground_signal:(Signal.map (fun selected -> if selected then "link" else "foreground") selected)
      ~label:(View_base.tr current title) ~accessibility_identifier:("tab.bottom." ^ name)
      ~on_press:(fun _ -> navigate destination action)
      [] in
  let action image title identifier event =
    icon_button ~icon:(`app image) ~variant:`ghost ~size:`icon ~width:cell ~height:cell
      ~foreground:"foreground"
      ~label:(View_base.tr current title) ~accessibility_identifier:identifier
      ~on_press:(press send event) [] in
  let group name width children =
    row ~width:(List.length children * width + 2 * inset)
         ~padding:inset ~gap:0 ~cross:`center
         ~accessibility_identifier:("group.bottom." ^ name) children in
  let tabs = custom (fun context parent ->
    let node = Lui_ui.extension context "bottom-tab-strip" in
    let selected = Signal.map (fun (current : Model.logseq_model) ->
      List.find_index (fun (destination, _, _, _, _, _) -> current.destination = destination)
        destinations |> Option.value ~default:(-1)) model_source in
    let items = Signal.map (fun current ->
      `List (List.map (fun (_, title, name, image, selected_image, _) ->
        `Assoc ["title", `String (View_base.tr current title); "name", `String name;
                "image", `String image; "selectedImage", `String selected_image])
        destinations) |> Yojson.Safe.to_string) model_source in
    Lui_ui.extension_property context node "inset" (IntValue inset);
    Lui_ui.extension_property context node "cell-width" (IntValue tab_width);
    Lui_ui.extension_property_signal context node "items" (Signal.map View_base.string_wire_value items);
    Lui_ui.extension_property_signal context node "selected-index" (Signal.map View_base.int_wire_value selected);
    Lui_ui.on_event context node (function
      | ExtensionEvent (_, _, "select", values) ->
        (match String_map.find_opt "index" values with
         | Some (IntValue index) when index >= 0 ->
           Option.iter (fun (destination, _, _, _, _, action) -> navigate destination action)
             (List.nth_opt destinations index)
         | _ -> ())
      | ExtensionEvent (_, _, "home-double-tap", _) ->
        ignore (send Model.ScrollHomeToTop)
      | _ -> ());
    ignore (mount context ~parent:node (group "tabs" tab_width (List.map tab destinations)));
    attach context parent node;
    node) in
  row ~grow:1.0 ~gap:8 ~main:`space_between ~cross:`center
    ~accessibility_identifier:"row.bottom.capture" [
      tabs;
      View_base.with_liquid_glass "bottom-actions" (group "actions" cell [
          action "bottom-search" "Search" "button.search" Model.OpenSearch;
          action "capture-circle" "Capture" "button.composer.expand" Model.ExpandComposer;
        ]);
    ]

let capture_and_search_row (context : Lui_ui.ui_context) model_source send
    : t =
  if uses_ios_native_header context then
    let show_flashcards = Signal.map (fun (current : Model.logseq_model) ->
      List.mem "flashcards" current.sidebar_tabs) model_source in
    reactive (fun show_flashcards -> bottom_tab_row ~show_flashcards model_source send) show_flashcards
  else if Lui_ui.host context = KotlinHost then
    row ~grow:1.0 ~gap:10 ~cross:`center
      ~accessibility_identifier:"row.bottom.capture"
      [
        View_composer.composer_view context model_source send;
        icon_button ~icon:(`app "search") ~variant:`ghost ~size:`icon ~width:56
          ~height:56 ~background:"surface-container-low" ~corner_radius:28
          ~foreground:"foreground" ~label:(View_base.tr (Signal.sample model_source) "Search")
          ~accessibility_identifier:"button.search"
          ~on_press:(press send Model.OpenSearch)
          [];
      ]
  else
    row ~grow:1.0 ~gap:10 ~cross:`center
      ~accessibility_identifier:"row.bottom.capture"
      [
        View_composer.composer_view context model_source send;
        View_base.with_liquid_glass "bottom-search"
          (icon_button ~icon:(`app "search") ~variant:`ghost ~size:`icon
             ~width:58 ~height:58 ~foreground:"foreground" ~label:(View_base.tr (Signal.sample model_source) "Search")
             ~accessibility_identifier:"button.search"
             ~on_press:(press send Model.OpenSearch)
             []);
      ]

let main_bottom_chrome ?(search_page = false) (context : Lui_ui.ui_context) model_source send : t
    =
  let primary_tabs = uses_ios_native_header context in
  let selection_chrome : t =
    column ~gap:0 ~padding_horizontal:16
      [
        View_outliner.outliner_selection_toolbar model_source send;
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
            (Signal.map (View_base.bottom_chrome_expanded_composer_ ~primary_tabs)
               model_source)
          (column ~gap:0 ~padding_horizontal:16
             [
               if_ ~test:(reactive View_base.composer_reference_active_ model_source)
                 (View_outliner.composer_reference_bar context model_source send);
               box ~height:6 [];
               row ~cross:`center
                 ~accessibility_identifier:"row.composer.placement"
                 [ View_composer.composer_view context model_source send ];
               box ~height:21 [];
             ]);
        if_
          ~test:
            (Signal.map (View_base.bottom_chrome_capture_and_search_ ~primary_tabs)
               model_source)
          (column ~gap:0 ~padding_horizontal:16
             [
               box ~height:8 [];
               capture_and_search_row context model_source send;
               box ~height:21 [];
             ]);
      ]
  else
    let selection_source = Signal.map (fun current ->
      match View_base.active_node_projection current with
      | Some route -> View_base.node_route_model ~active:true current route
      | None -> current) model_source in
    let selects = Signal.map (fun current ->
      current.Model.search_open = search_page && View_base.bottom_chrome_selection_ current)
      selection_source in
    let captures =
      Signal.map (View_base.bottom_chrome_capture_and_search_ ~primary_tabs) model_source in
    let selection_chrome ?(retain_task_actions = false) () =
      column ~gap:0 [
        box ~height:8 [];
        View_outliner.outliner_selection_toolbar ~retain_task_actions selection_source send;
        box ~height:21 [];
      ] in
    let capture_chrome =
      column ~container_relative_frame:`horizontal ~cross:`stretch
        ~gap:0 ~padding_horizontal:16 [
          box ~height:8 [];
          capture_and_search_row context model_source send;
          box ~height:21 [];
        ] in
    let navigation_chrome =
      if primary_tabs && not search_page then
        if_ ~test:(Signal.map2 ( || ) selects captures)
          (custom (fun context parent ->
            let node = Lui_ui.extension context "bottom-chrome-switch" in
            attach context parent node;
            Lui_ui.extension_property_signal context node "selection-active"
              (Signal.map (fun selected -> BoolValue selected) selects);
            ignore (mount context ~parent:node
              (box ~inert_signal:selects [capture_chrome]));
            ignore (mount context ~parent:node
              (box ~inert_signal:(Signal.map not selects) [selection_chrome ~retain_task_actions:true ()]));
            node))
      else
        stack [
          if_ ~test:selects (selection_chrome ());
          if_ ~test:captures capture_chrome;
        ] in
    stack
      [
        navigation_chrome;
        if_
          ~test:(reactive View_base.bottom_chrome_editor_ model_source)
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
            (Signal.map (View_base.bottom_chrome_expanded_composer_ ~primary_tabs)
               model_source)
          (column ~container_relative_frame:`horizontal ~cross:`stretch
             ~gap:0 ~padding_horizontal:16
             [
               if_ ~test:(reactive View_base.composer_reference_active_ model_source)
                 (View_base.with_liquid_glass "container"
                    (View_outliner.composer_reference_bar context model_source send));
               box ~height:6 [];
               row ~cross:`center
                 ~accessibility_identifier:"row.composer.placement"
                 [ View_composer.composer_view context model_source send ];
               box ~height:21 [];
             ]);
      ]

let root_outliner_view ?scroll_to_top (context : Lui_ui.ui_context) model_source visible_source
    send : t =
  let prefetch_history () =
    Signal.sample visible_source
    && View_base.older_journals_visible_ (Signal.sample model_source)
    && send Model.LoadOlderJournals in
  let list_style = Signal.map (fun (current : Model.logseq_model) ->
    if current.selected_page <> None && View_base.selected_page_journal_day current = None then
      "retained-pane scroll-section-titles"
    else "retained-pane") model_source in
  View_base.with_reading_insets
    (box ~grow:1.0 ~accessibility_identifier:"layout.outliner.horizontal-inset"
    [
      (* Each graph owns a fresh native scroll view and virtual window. *)
      keyed
        ~source:(Signal.map (fun (current : Model.logseq_model) ->
          [Option.value ~default:"local" current.selected_graph_id]) model_source)
        ~key:Fun.id ~cmp:String.compare
        ~mount:(fun _ -> View_outliner.with_result_page ~root:true context model_source send
        (View_base.with_selected_signal visible_source
        (View_base.with_string_prop_signal StyleClass list_style
        (virtual_list ~grow:1.0
           ~data_attrs_signal:(Signal.map (fun current ->
             ["data-scroll-identity", View_base.outliner_scroll_identity current]) model_source)
           ~accessibility_identifier:"list.outliner"
        [
          box ~height:16 ~accessibility_identifier:"spacer.outliner.top"
            ?data_attrs_signal:(Option.map (Signal.map (function
              | "" -> []
              | key -> ["data-scroll-key", key; "data-scroll-index", "0"])) scroll_to_top)
            [];
          if_
            ~test:
              (Signal.map View_base.selected_page_content_title_visible_
                 model_source)
            (column ~gap:0
               [
                 box ~padding_horizontal:16
                   ~accessibility_identifier:"layout.selected-page.title"
                   [
                     row ~gap:8 ~cross:`center (
                     View_base.node_icon_view ~size:28 (Signal.map (fun (current : Model.logseq_model) ->
                       match current.selected_page with Some page -> View_base.node_icon current page.uuid | None -> "") model_source)
                     :: View_outliner.page_heading_text ~accessibility_identifier:"title.selected-page"
                       (Signal.map View_base.selected_page_title_parts model_source));
                   ];
                 reactive (fun has_properties -> View_outliner.page_title_spacer ~has_properties ())
                   (Signal.map (fun (model : Model.logseq_model) -> View_property.has_properties model.properties_json) model_source);
               ]);
          View_outliner.node_properties ~root:true context model_source send;
          View_outliner.outliner_entries ~prefetch_history ?reset_key:scroll_to_top context model_source
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
          View_outliner.outliner_bottom_spacer ();
          ]))));
    ])

let retained_journal_pane (context : Lui_ui.ui_context) model_source send
    : t =
  let scroll_to_top =
    if uses_ios_native_header context then
      Some (Signal.map (fun (current : Model.logseq_model) ->
        if current.home_scroll_request = 0 then ""
        else "home-top-" ^ string_of_int current.home_scroll_request) model_source)
    else None in
  let content =
    root_outliner_view ?scroll_to_top context
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
      send
  in
  box ~grow:1.0 ~accessibility_identifier:"pane.journals" [content]

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

let graph_loading_feedback (context : Lui_ui.ui_context) model_source : t
    =
  if Lui_ui.host context = KotlinHost then
    View_base.with_string_prop AlignmentValue "center"
      (column ~grow:1.0 ~main:`center ~cross:`center ~gap:12
         ~background:"background"
         ~accessibility_identifier:"journals.loading"
         [
           spinner ~accessibility_identifier:"spinner.graph-loading" [];
           text
             ~value:
               (reactive View_base.graph_loading_message model_source)
             ~foreground:"muted-foreground" ~text_alignment:`center [];
         ])
  else
    column ~grow:1.0 ~main:`center ~cross:`center
      ~accessibility_identifier:"journals.loading"
      [ spinner ~accessibility_identifier:"spinner.graph-loading" [] ]

let logseq_main_view (context : Lui_ui.ui_context) model_source send : t
    =
  stack ~grow:1.0
    [
      if_
        ~test:(reactive View_base.journal_tree_retained_ model_source)
        (journal_tree_panes context model_source send);
      if_
        ~test:(reactive View_base.tasks_destination_ model_source)
        (View_outliner.tasks_screen context model_source send);
      if_
        ~test:(Signal.map View_base.flashcards_destination_ model_source)
        (View_flashcards.flashcard_screen
           ~uses_header:(uses_ios_native_header context || Lui_ui.host context = KotlinHost)
           ~bottom_spacing:(if uses_ios_native_header context then 64 else 24)
           model_source send);
      if_
        ~test:(Signal.map View_base.graphs_destination_ model_source)
        (View_graphs.graphs_screen context model_source send);

      if_
        ~test:(Signal.map View_base.graph_loading_visible_ model_source)
        (graph_loading_feedback context model_source);
    ]

let main_header_model context current =
  if Lui_ui.host context = KotlinHost then current
  else View_base.navigation_root_model current

let main_header_leading_content (context : Lui_ui.ui_context)
    ~source:model_source send : t =
  let allow_during_editing =
    Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost in
  stack
    [
      if_
        ~test:
          (Signal.map
             (fun (current : Model.logseq_model) ->
               Lui_ui.host context = KotlinHost
               && View_base.node_screen_visible_ current)
             model_source)
        (icon_button ~icon:(`app "navigation-back") ~variant:`ghost ~size:`icon
           ~label:(View_base.tr (Signal.sample model_source) "Back")
           ~accessibility_identifier:"button.navigation.back"
           ~on_press:(fun _ ->
             ignore (send (Model.BackAppNavigation 1)))
           []);
      if_
        ~test:
          (Signal.map View_base.primary_sidebar_button_visible_
             model_source)
        (icon_button ~icon:(`app "sidebar-toggle") ~variant:`ghost ~size:`icon
           ~width:44 ~height:44
           ~label:(View_base.tr (Signal.sample model_source) "Toggle sidebar")
           ~style_class:"drawer-toggle"
           ~accessibility_identifier:"button.sidebar"
           ~disabled_signal:
             (Signal.map (View_base.sidebar_button_disabled_ ~allow_during_editing)
                model_source)
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
  let android = Lui_ui.host context = KotlinHost in
  text
    ?grow:(if android then Some 1.0 else None)
    ?white_space:(if android then Some `nowrap else None)
    ?text_overflow:(if android then Some `ellipsis else None)
    ~value:
      (reactive
         (fun current ->
           let title = View_base.main_title (main_header_model context current) in
           if android then View_base.ellipsize_middle title 16 else title)
         model_source)
    ~style_class:"headline navigation-title" ~accessibility_identifier:"title.main" []

let journal_calendar_control model_source send =
  icon_button ~icon:(`app "calendar") ~label:(View_base.tr (Signal.sample model_source) "Go to journal")
    ~variant:`ghost ~size:`icon ~width:44 ~height:44
    ~accessibility_identifier:"button.journal-calendar"
    ~on_press:(press send Model.OpenJournalCalendar) []

let open_sync_status model_source send () =
  let current = Signal.sample model_source in
  ignore (send (if current.Model.authentication_state = "signedIn" then Model.OpenSyncDetails else Model.SignIn))

let journal_overflow_menu model_source send =
  box ~width:44 ~height:44 [
    menu ~icon:(`app "more-horiz") ~style_class:"capsule"
      ~label:(View_base.tr (Signal.sample model_source) "More")
      ~accessibility_identifier:"button.journals.more" [
        dropdown_menu_item ~icon:(`app "status-dot")
          ~foreground_signal:(Signal.map View_base.sync_indicator_foreground model_source)
          ~text_signal:(Signal.map View_base.sync_indicator_label model_source)
          ~accessibility_identifier_signal:(Signal.map View_base.sync_accessibility_identifier model_source)
          ~on_press:(open_sync_status model_source send) []
      ]
  ]

let ios_journal_header context current =
  uses_ios_native_header context && View_base.journal_home_visible_ current

let main_header_primary_action (context : Lui_ui.ui_context) model_source send : t =
  stack [
    if uses_ios_native_header context then
      if_ ~test:(Signal.map (ios_journal_header context) model_source)
        (journal_calendar_control model_source send)
    else
      if_
        ~test:
          (Signal.map View_base.connection_control_visible_ model_source)
        (View_base.with_label_signal
           (Signal.map View_base.sync_indicator_label model_source)
           (icon_button ~label:(View_base.tr (Signal.sample model_source) "Sync status")
              ~icon:(`app "status-dot")
              ~variant:`ghost ~size:`icon
              ~foreground_signal:
                (Signal.map View_base.sync_indicator_foreground
                   model_source)
              ~accessibility_identifier_signal:
                (Signal.map View_base.sync_accessibility_identifier
                   model_source)
              ~on_press:(fun _ -> open_sync_status model_source send ())
              []))
  ]

let active_overflow_menu model_source send : t =
 custom @@ fun context parent ->
   let page_actions_source =
     Signal.map View_base.active_page_actions_visible_ model_source
   in
   let settings_source =
     Signal.map View_base.connection_settings_visible_ model_source
   in
   let own source = Signal.own_signal context.ui_scope source in
   let raw_source = own (Signal.map (fun current -> match View_base.active_node_projection current with
     | Some route -> route.Model.node_properties_json | None -> current.Model.properties_json) model_source) in
   let rename_source = own (Signal.map View_property.rename_page raw_source) in
   let tag_source = own (Signal.map View_property.tag_picker raw_source) in
   let tag_schema_source = own (Signal.map View_property.has_tag_schema raw_source) in
   let tag_properties_open = Signal.state context.ui_scheduler false in
   let tag_properties_owner = ref None in
   let editing = Signal.state context.ui_scheduler None in
   let finished = ref None in
   ignore (Signal.own context.ui_scope (Signal.observe model_source (fun (current : Model.logseq_model) ->
     let owner = current.selected_graph_id, View_property.owner_uuid (Signal.sample raw_source) in
     if !tag_properties_owner <> Some owner then Signal.set tag_properties_open false;
     match Signal.sample (Signal.value editing) with
     | Some (graph, owner, action, _) ->
       let active_owner = match Signal.sample tag_source with Some (owner, _) -> Some owner
         | None -> Option.map fst (Signal.sample rename_source) in
       if current.selected_graph_id <> graph || active_owner <> Some owner then
         Signal.set editing None
       else (match List.find_opt (fun (key, _, _) -> key = "page." ^ action ^ "." ^ owner) current.result_view_feedback with
         | Some (_, revision, error) when !finished <> Some revision ->
           finished := Some revision; if error = None then Signal.set editing None
         | _ -> ())
     | None -> ())));
   let kotlin_host = Lui_ui.host context = KotlinHost in
   (* iOS menu items carry no icons; the Kotlin popup did. *)
   let item_icon name = if kotlin_host then Some (`app name) else None in
   mount context ?parent (View_property.with_add_property_picker model_source raw_source send (fun _ add_property add_picker ->
   let entries =
     [ if_dropdown_menu_item ~test:page_actions_source
         (if kotlin_host then
            dropdown_menu_item
              ~text_signal:
                (Signal.map (fun current ->
                   View_base.tr current (View_base.active_page_favorite_label current))
                   model_source)
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
            dropdown_menu_item
              ~text_signal:
                (Signal.map (fun current ->
                   View_base.tr current (View_base.active_page_favorite_label current))
                   model_source)
              ~on_press:(press send Model.ToggleActivePageFavorite)
              []);
       if_dropdown_menu_item ~test:(own (Signal.map (fun source -> Option.is_some source) rename_source))
         (dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Rename page") ~accessibility_identifier:"button.page.rename"
           ~on_press:(fun _ ->
             let current = Signal.sample model_source in
             match Signal.sample rename_source with
             | None -> ()
             | Some (owner, property) ->
               finished := Option.map (fun (_, revision, _) -> revision)
                 (List.find_opt (fun (key, _, _) -> key = "page.rename." ^ owner) current.Model.result_view_feedback);
               Signal.set editing (Some (current.selected_graph_id, owner, "rename", property))) []);
       if_dropdown_menu_item ~test:(own (Signal.map Option.is_some tag_source))
         (dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Set tags") ~accessibility_identifier:"button.page.tags"
           ~on_press:(fun _ -> match Signal.sample tag_source with
             | None -> ()
             | Some (owner, property) -> let current = Signal.sample model_source in
               finished := Option.map (fun (_, revision, _) -> revision)
                 (List.find_opt (fun (key, _, _) -> key = "page.tags." ^ owner) current.Model.result_view_feedback);
               Signal.set editing (Some (current.selected_graph_id, owner, "tags", property))) []);
       add_property;
       if_dropdown_menu_item ~test:tag_schema_source
         (dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Tag properties")
           ~accessibility_identifier:"button.page.tag-properties"
           ~on_press:(fun _ ->
             tag_properties_owner := Some ((Signal.sample model_source).Model.selected_graph_id,
               View_property.owner_uuid (Signal.sample raw_source));
             Signal.set tag_properties_open true) []);
       if_dropdown_menu_item ~test:page_actions_source
         (dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Share") ?icon:(item_icon "share")
            ~on_press:(press send Model.ShareActivePage)
            []);
       keyed_dropdown_menu_item ~source:(own (Signal.map (fun model -> Option.to_list (Model.active_delete_target model)) model_source))
         ~key:(function Model.BlockToDelete _ -> `Block | Model.PageToDelete _ -> `Page) ~cmp:compare
         ~mount:(fun source -> match Signal.sample source with
         | Model.BlockToDelete _ ->
           dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Delete block") ~variant:`destructive
             ~accessibility_identifier:"button.block.delete" ?icon:(item_icon "toolbar-delete")
             ~on_press:(press send Model.RequestDeleteActiveNode) []
         | Model.PageToDelete _ ->
           dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Delete") ~variant:`destructive
             ~accessibility_identifier:"button.page.delete" ?icon:(item_icon "toolbar-delete")
             ~on_press:(press send Model.RequestDeleteActiveNode) []);
       if_dropdown_menu_item ~test:settings_source
         (dropdown_menu_item ~text:(View_base.tr (Signal.sample model_source) "Settings") ?icon:(item_icon "settings")
            ~on_press:(press send Model.OpenSettings)
            []);
     ]
   in
   let menu = if kotlin_host then
     menu ~icon:(`app "more-vert") ~label:(View_base.tr (Signal.sample model_source) "More")
       ~accessibility_identifier:"button.overflow-menu" entries
   else
     box ~width:44 ~height:44
       [ menu ~icon:(`app "more-horiz") ~style_class:"capsule" ~label:(View_base.tr (Signal.sample model_source) "More")
           ~accessibility_identifier:"button.connection" entries ] in
   stack [menu; add_picker;
     if_ ~test:(Signal.value tag_properties_open)
       (View_property.tag_properties model_source raw_source send (fun () -> Signal.set tag_properties_open false));
     if_ ~test:(own (Signal.map Option.is_some (Signal.value editing)))
       (reactive (function None -> box [] | Some (graph, owner, action, property) ->
         let column = if action <> "rename" then property else match property with `Assoc fields ->
           `Assoc (("title", `String "Rename page") :: List.remove_assoc "title" fields) | value -> value in
         View_query.property_editor ~owner ~send ~id:("page." ^ action ^ "." ^ owner) ~column
           ~submit:(fun fields -> ignore (send (Model.SubmitNodeProperty ("page." ^ action ^ "." ^ owner,
             Yojson.Basic.to_string (`Assoc (("blockUuid", `String owner) ::
               ("graphId", `String (Option.value ~default:"" graph)) ::
               (if action = "tags" then ("action", `String "setTags") :: fields else fields)))))))
           model_source property (fun () -> Signal.set editing None)) (Signal.value editing));
   ]))

let header_selection_active current =
  match View_base.active_node_projection current with
     | Some route -> route.Model.node_outliner_selected_block_ids <> []
     | None -> View_base.bottom_chrome_selection_ current

let selection_done model_source send =
  icon_button ~icon:(`app "selection-done") ~variant:`ghost ~size:`icon ~width:44 ~height:44
    ~style_class:"system-toolbar-icon" ~label:(View_base.tr (Signal.sample model_source) "Done")
    ~accessibility_identifier:"button.outliner.selection.done"
    ~on_press:(press send (Model.PerformOutlinerToolbarAction "unselect")) []

let main_header_connection model_source send : t = custom @@ fun context parent ->
  let selecting = Signal.map header_selection_active model_source in
  let controls = stack
    [
      if_
        ~test:
          (Signal.map View_base.connection_control_visible_ model_source)
        (custom @@ fun context parent ->
          mount context ?parent (stack [
               (if uses_ios_native_header context then
                  if_ ~test:(Signal.map View_base.graphs_destination_ model_source)
                    (icon_button ~icon:(`app "add") ~variant:`ghost ~width:44 ~height:44
                      ~style_class:"system-toolbar-icon"
                      ~label:(View_base.tr (Signal.sample model_source) "Add sync graph")
                      ~accessibility_identifier:"button.graph-add" ~on_press:(press send Model.OpenCreateGraph) [])
                else if_ ~test:(Signal.map View_base.connection_settings_visible_ model_source)
                  (journal_calendar_control model_source send));
               if_ ~test:(Signal.map (ios_journal_header context) model_source)
                 (journal_overflow_menu model_source send);
               if_ ~test:(Signal.map (fun current ->
                 uses_ios_native_header context && View_base.tasks_destination_ current
                 && View_base.node_navigation_inactive_ current) model_source)
                 (View_outliner.tasks_menu model_source send);
               if_ ~test:(Signal.map View_base.active_page_actions_visible_ model_source)
                 (active_overflow_menu model_source send)]));
    ] in
  if Lui_ui.host context = SwiftUIHost then
    mount context ?parent (stack [box [controls]; box [selection_done model_source send]])
  else
    mount context ?parent (reactive (fun selecting ->
      if selecting then selection_done model_source send else controls) selecting)

let native_node_destination ~source:title_source content : t =
 custom @@ fun context parent ->
   let node = Lui_ui.platform_tweak context "native-navigation-title" in
   Lui_ui.extension_property_signal context node "title" title_source;
   ignore (mount context ~parent:node content);
   attach context parent node;
   node

let native_node_screen (context : Lui_ui.ui_context) model_source
    ~source:route_source send : t =
  let route_model_source =
    Signal.map2 (fun current (route, active) ->
      View_base.node_route_model ~active current route) model_source route_source
  in
  if Lui_ui.host context = KotlinHost then
    View_base.with_string_prop_signal DisplayValue
      (Signal.map (fun (_, active) -> if active then "contents" else "none") route_source)
      (View_base.with_float_prop_signal GrowValue
         (Signal.map (fun (_, active) -> if active then 1.0 else 0.0) route_source)
         (box ~background:"background"
            [ View_outliner.node_screen context route_model_source send ]))
  else
    native_node_destination
      ~source:
        (reactive
           (fun current -> StringValue
             (if View_base.node_title_visible_ current then ""
              else View_base.active_node_title current))
           route_model_source)
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
        ~source:(Signal.map2 (fun routes (index, route) ->
          (route, index = List.length routes - 1)) routes_source visit_source) send)

let native_search_view ?base (_context : Lui_ui.ui_context) model_source send :
    t =
 custom @@ fun context parent ->
   let node = Lui_ui.extension context "native-search-presentation" in
   attach context parent node;
   let presented_source =
     Signal.map View_base.model_search_open_ model_source
   in
   let depth_source =
     Signal.map View_base.search_navigation_depth model_source
   in
   let query_source = Signal.map View_base.model_search_query model_source in
   Lui_ui.extension_property_signal context node "back-title"
     (Signal.map (fun current -> StringValue (View_base.tr current "Back")) model_source);
   Lui_ui.extension_property_signal context node "clear-title"
     (Signal.map (fun current -> StringValue (View_base.tr current "Clear")) model_source);
   Lui_ui.extension_property_signal context node "close-title"
     (Signal.map (fun current -> StringValue (View_base.tr current "Close")) model_source);
   Lui_ui.extension_property_signal context node "presented"
     (Signal.map View_base.bool_wire_value presented_source);
   Lui_ui.extension_property_signal context node "depth"
     (Signal.map View_base.int_wire_value depth_source);
   Lui_ui.extension_property_signal context node "query"
     (Signal.map View_base.string_wire_value query_source);
   Lui_ui.extension_property_signal context node "status-title"
     (Signal.map (fun current ->
       let status = View_base.search_result_status current in
       StringValue (if status = "" then View_base.tr current "Search" else status)) model_source);
   Lui_ui.extension_property_signal context node "title"
     (Signal.map (fun (current : Model.logseq_model) -> StringValue
       (if Lui_ui.host context = SwiftUIHost || current.search_navigation_path = [] then View_base.tr current "Search"
        else View_base.active_node_title current)) model_source);
   Lui_ui.extension_property_signal context node "bottom-occupies-layout-space"
     (Signal.map (fun current -> BoolValue (View_base.search_editor_active_ current)) model_source);
   Lui_ui.on_event context node (fun input_event ->
       ignore (View_base.handle_native_search_event input_event send));
   if Lui_ui.host context = KotlinHost then
     let _ =
       mount context ~parent:node (stack ~grow:1.0
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
         ])
     in
     ignore (mount context ~parent:node (if_ ~test:(Signal.map (fun (current : Model.logseq_model) ->
       current.search_open && current.search_navigation_path <> []) model_source)
       (reactive (fun selecting -> if selecting then selection_done model_source send
          else active_overflow_menu model_source send) (Signal.map header_selection_active model_source))));
     node
   else (
     ignore
       (mount context ~parent:node (match base with
         | Some view -> box ~grow:1.0 [view]
         | None -> logseq_main_view context (Signal.map View_base.navigation_root_model model_source) send));
     ignore
       (mount context ~parent:node (column ~grow:1.0 [ search_screen model_source send ]));
     (* Keep the chrome anchor present while idle so native route indices stay stable. *)
     ignore
       (mount context ~parent:node (column ~gap:0
           [if_ ~test:(reactive (fun current ->
              View_base.search_editor_active_ current || header_selection_active current) model_source)
              (main_bottom_chrome ~search_page:true context model_source send)]));
     ignore (mount context ~parent:node (main_header_connection model_source send));
     ignore
       (mount context ~parent:node (native_node_stack context model_source
           ~source:(reactive View_base.search_node_routes model_source) send));
     node)

let android_main_header context model_source send =
  let round_action action =
    column ~width:44 ~height:44 ~corner_radius:22
      ~background:"glass" ~main:`center ~cross:`center [action] in
  let header controls =
    row ~cross:`center ~gap:8 ~height:64 ~padding_horizontal:16
      ~accessibility_identifier:"header.main"
      (round_action (main_header_leading context model_source send) :: controls) in
  let title = dyn (fun journals ->
      if journals then column ~grow:1.0 ~cross:`center [View_sidebar.android_graph_switch model_source send]
      else main_header_title context model_source)
    (Signal.map (fun current -> View_base.journals_sidebar_selected_ current
      && View_base.app_navigation_depth current = 0) model_source) in
  let default_header = header [
    title;
    reactive (fun selecting ->
      if selecting then round_action (selection_done model_source send)
      else box ~corner_radius:22 ~background:"glass" ~padding_horizontal:6
        [row ~cross:`center ~gap:4 [
          main_header_primary_action context model_source send;
          main_header_connection model_source send;
        ]]) (Signal.map header_selection_active model_source);
  ] in
  let flashcard_header =
    View_flashcards.android_flashcard_header model_source send
      ~render:(fun menu add ->
        header [column ~grow:1.0 ~cross:`center [menu]; round_action add]) in
  if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> not current.search_open) model_source)
    (dyn (fun flashcards -> if flashcards then flashcard_header else default_header)
       (Signal.map View_base.flashcards_destination_ model_source))

let native_navigation_view (_context : Lui_ui.ui_context) model_source send
    : t =
 custom @@ fun context parent ->
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
     Signal.map (View_base.bottom_chrome_expanded_composer_ ~primary_tabs:(uses_ios_native_header context)) model_source
   in
   let title_source =
     Signal.map
       (fun current ->
         let current = main_header_model context current in
         if (uses_ios_native_header context && View_base.tasks_destination_ current)
           || (View_base.journals_destination_ current && View_base.selected_page_content_title_visible_ current) then ""
         else View_base.main_title current)
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
   Lui_ui.extension_property_signal context node "selection-active"
     (Signal.map (fun current -> BoolValue (header_selection_active current)) model_source);
   Lui_ui.on_event context node (fun input_event ->
       ignore
         (View_base.handle_native_navigation_event input_event send));
   if Lui_ui.host context = KotlinHost then (
     (* Two extension children: [content, bottom chrome]. The host hoists
        the second child to a bottom inset/overlay (mirroring the iOS
        bottomChromeIndex); inside the content column its internal `grow`
        props would starve the weighted journal content. *)
     ignore
       (mount context ~parent:node (stack ~grow:1.0
           [
             column ~grow:1.0
               [
                 android_main_header context model_source send;
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
           ]));
     ignore
       (mount context ~parent:node (main_bottom_chrome context model_source send));
     node)
   else (
     ignore
       (mount context ~parent:node (column [
          logseq_main_view context (Signal.map View_base.navigation_root_model model_source) send;
        ]));
     ignore
       (mount context ~parent:node (main_header_leading context model_source send));
     let title_slot =
       if uses_ios_native_header context then
         let viewport = Signal.map (fun (current : Model.logseq_model) -> current.viewport_width) model_source in
         let width = Signal.map (fun viewport ->
           (* Leave space for the sidebar toggle, two trailing actions, and bar margins. *)
           max 44 (min 320 (viewport - 3 * 44 - 2 * 16 - 2 * 12))) viewport in
         (* Give the native toolbar its settled title width before showing the menu. *)
         let display = Signal.map (fun width -> if width > 0 then "block" else "none") viewport in
         let title = box ~accessibility_identifier:"title.main"
           [View_base.with_string_prop_signal DisplayValue display
              (box [View_base.with_int_prop_signal WidthValue width
                (View_sidebar.native_graph_switch ~min_height:28 ~foreground:"muted-foreground" model_source send)])] in
         dyn (function
           | `Flashcards -> box [View_flashcards.flashcard_toolbar model_source send]
           | `Journals -> title
           | `Page -> box []) (Signal.map (fun current ->
             if View_base.flashcards_destination_ current then `Flashcards
             else if View_base.journals_sidebar_selected_ current then `Journals
             else `Page) model_source)
       else main_header_title context model_source in
     ignore (mount context ~parent:node title_slot);
     ignore
       (mount context ~parent:node (main_header_primary_action context model_source send));
     ignore
       (mount context ~parent:node (main_header_connection model_source send));
     ignore
       (mount context ~parent:node (main_bottom_chrome context model_source send));
     ignore
       (mount context ~parent:node (native_node_stack context model_source
           ~source:(reactive Model.app_node_routes model_source) send));
     ignore
       (mount context ~parent:node (if_
           ~test:(Signal.map View_base.asset_preview_ model_source)
           (file_preview
              ~path_signal:
                (Signal.map View_base.asset_preview_path model_source)
              ~on_dismiss:(press send Model.DismissAssetPreview)
              [])));
     if Lui_ui.host context = SwiftUIHost then
       ignore
         (mount context ~parent:node (column ~gap:0 ~width:44
             ~accessibility_identifier:"navigation.capture-controls"
             [
               icon_button ~icon:(`app "toolbar-camera") ~variant:`ghost ~size:`icon
                 ~style_class:"system-toolbar-icon"
                 ~width:44 ~height:44 ~foreground:"foreground"
                 ~label:(View_base.tr (Signal.sample model_source) "Take photo")
                 ~accessibility_identifier:"button.navigation.camera"
                 ~on_press:(press send (Model.ChooseAttachment "camera")) [];
               icon_button ~icon:(`app "toolbar-audio") ~variant:`ghost ~size:`icon
                 ~style_class:"system-toolbar-icon"
                 ~width:44 ~height:44 ~foreground:"foreground"
                 ~label:(View_base.tr (Signal.sample model_source) "Audio recording")
                 ~accessibility_identifier:"button.navigation.audio"
                 ~on_press:(press send (Model.ChooseAttachment "audio")) [];
               icon_button ~icon:(`app "search") ~variant:`ghost ~size:`icon
                 ~style_class:"system-toolbar-icon"
                 ~width:44 ~height:44 ~foreground:"foreground"
                 ~label:(View_base.tr (Signal.sample model_source) "Search")
                 ~accessibility_identifier:"button.navigation.search"
                 ~on_press:(press send Model.OpenSearch) [];
               icon_button ~icon:(`app "capture-circle") ~variant:`ghost ~size:`icon
                 ~style_class:"system-toolbar-icon"
                 ~width:44 ~height:44 ~foreground:"foreground"
                 ~label:(View_base.tr (Signal.sample model_source) "Capture")
                 ~accessibility_identifier:"button.navigation.capture"
                 ~on_press:(press send Model.ExpandComposer) [];
             ]));
     node)

let authentication_content (context : Lui_ui.ui_context) model_source
    send : t =
  let sign_in =
    button ~accessibility_identifier:"button.sign-in"
      ~variant:`primary ~size:`lg ~grow:1.0
      ?text_alignment:(if Lui_ui.host context = KotlinHost then None else Some `center)
      ~disabled:(reactive View_base.authentication_signing_in_ model_source)
      ~on_press:(press send Model.SignIn)
      ~text:(View_base.tr (Signal.sample model_source) "Sign in")
      [View_settings.sign_in_label ~centered:true model_source]
  in
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
      heading ~level:`h1 ~value:(View_base.tr (Signal.sample model_source) "Logseq") [];
      box ~height:10 [];
      text ~foreground:"muted-foreground" ~text_alignment:`center
        ~value:(View_base.tr (Signal.sample model_source) "Capture, sync, and review your notes anywhere.") [];
      box ~height:36 [];
      (if Lui_ui.host context = KotlinHost then
         row ~cross:`center [sign_in]
       else sign_in);
    ]

let authentication_screen (context : Lui_ui.ui_context) model_source send
    : t =
  if Lui_ui.host context = KotlinHost then
    overlay ~accessibility_identifier:"screen.authentication" ~grow:1.0
      ~alignment:`center
      [ box [];
        scroll ~max_width:464 ~padding:32
          [authentication_content context model_source send] ]
  else
    column ~accessibility_identifier:"screen.authentication" ~grow:1.0
      ~container_relative_frame:`vertical ~main:`center ~cross:`center
      [ view_that_fits ~orientation:`vertical
          [ column ~padding_horizontal:32 ~padding_vertical:64 ~cross:`center
              [authentication_content context model_source send];
            scroll ~max_width:464 ~padding_horizontal:32 ~padding_vertical:64
              [authentication_content context model_source send] ] ]

let application_main_content (context : Lui_ui.ui_context) model_source
    send : t =
  let content_children : t list =
    if Lui_ui.platform context = AndroidOS then
      [
        if_
          ~test:(reactive View_base.main_screen_visible_ model_source)
          (native_navigation_view context model_source send);
        if_
          ~test:
            (Signal.map View_base.graph_picker_screen_visible_
               model_source)
          (View_graphs.graph_picker_screen context model_source send);
        if_
          ~test:(reactive View_base.model_settings_open_ model_source)
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
          ~test:(Signal.map View_base.node_deletion_pending_ model_source)
          (View_settings.page_delete_dialog model_source context send);
        if_
          ~test:(Signal.map View_base.sign_out_pending_ model_source)
          (View_settings.sign_out_dialog model_source context send);
        if_
          ~test:(Signal.map View_base.model_sync_details_open_
                   model_source)
          (View_settings.sync_status_sheet context model_source send);
      ]
    else
      [
        if_
          ~test:(reactive View_base.main_screen_visible_ model_source)
          (native_search_view ~base:(native_navigation_view context
             (Signal.map (fun (current : Model.logseq_model) ->
               let base = if current.search_open then View_base.without_outliner_interaction current else current in
               { base with search_open = false; search_navigation_path = [] }) model_source) send)
             context model_source send);
        if_
          ~test:(Signal.map (fun current ->
            (Lui_ui.platform context <> IOS || Lui_ui.host context <> SwiftUIHost)
            && View_base.authentication_screen_visible_ current) model_source)
          (authentication_screen context model_source send);
        if_
          ~test:
            (Signal.map View_base.graph_picker_screen_visible_
               model_source)
          (View_graphs.graph_picker_screen context model_source send);
        if_
          ~test:(reactive View_base.model_settings_open_ model_source)
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
          ~test:(Signal.map View_base.node_deletion_pending_ model_source)
          (View_settings.page_delete_dialog model_source context send);
        if_
          ~test:(Signal.map View_base.sign_out_pending_ model_source)
          (View_settings.sign_out_dialog model_source context send);
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
        let duration = if Lui_ui.platform context = IOS then 1500 else 2500 in
        let notification = toast ~duration ~label:(View_base.tr (Signal.sample model_source) "Added to today") ~margin_top:8
          ~on_dismiss:(press send (Model.DismissCaptureConfirmation (Signal.sample id_source)))
          [text ~value:(View_base.tr (Signal.sample model_source) "✅") ~accessibility_identifier:"capture.confirmation.icon" [];
           text ~value:(View_base.tr (Signal.sample model_source) "Added to today") ~accessibility_identifier:"capture.confirmation" []] in
        if Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost then
          box [(custom @@ fun context parent ->
            let node = Lui_ui.extension context "native-top-notification" in
            attach context parent node;
            ignore (mount context ~parent:node notification);
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

let application_sidebar model_source send ~width main : t =
  let selected = Signal.map View_base.drawer_selected_ model_source in
  let disabled = Signal.map View_base.drawer_disabled_ model_source in
  let navigate open_ = ignore (send (if open_ then Model.OpenSidebar else Model.CloseSidebar)) in
  let shell main panel =
    drawer ~selected_signal:selected ~disabled_signal:disabled ~width
      ~label:(View_base.tr (Signal.sample model_source) "Navigation")
      ~accessibility_identifier:"application.shell" ~on_toggle:navigate main panel in
  custom (fun context parent ->
    let ios = Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost in
    let android = Lui_ui.platform context = AndroidOS && Lui_ui.host context = KotlinHost in
    let settings = View_sidebar.sidebar_settings context model_source send in
    let panel settings = View_sidebar.sidebar_view context model_source send ~settings in
    if not (ios || android) then
      mount context ?parent (shell main (panel (Some settings)))
    else
      let node = Lui_ui.extension context "sidebar-overlay" in
      attach context parent node;
      Lui_ui.extension_property_signal context node "open" (Signal.map (fun open_ -> BoolValue open_) selected);
      Lui_ui.extension_property_signal context node "enabled" (Signal.map (fun disabled -> BoolValue (not disabled)) disabled);
      Lui_ui.extension_property context node "width" (IntValue width);
      Lui_ui.extension_property_signal context node "dismiss-label"
        (Signal.map (fun current -> StringValue (View_base.tr current "Close sidebar")) model_source);
      let child key body = custom (fun context parent ->
        let id = mount context ?parent body in
        Lui_ui.extension_property context node key (IntValue id);
        id) in
      Lui_ui.on_event context node (function
        | ExtensionEvent (_, _, "open", _) -> navigate true
        | ExtensionEvent (_, _, "close", _) -> navigate false
        | _ -> ());
      let settings = child "settings-id" settings in
      let panel = panel (if android then None else Some settings) in
      ignore (mount context ~parent:node (shell (child "main-id" main) (child "panel-id" panel)));
      if android then ignore (mount context ~parent:node settings);
      node)

let application_drawer_view (context : Lui_ui.ui_context) model_source send : t =
  let drawer_main = application_main_content context model_source send in
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
            ~test:(reactive View_base.application_shell_visible_ model_source)
            (application_sidebar model_source send ~width:320 drawer_main);
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
            ~test:(reactive View_base.application_shell_visible_ model_source)
            (application_sidebar model_source send ~width:360 drawer_main);
        ]
  else
    let ios_drawer = Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost in
    let dark_theme = Signal.map (fun (current : Model.logseq_model) -> current.dark_theme) model_source in
    let drawer_main =
      if ios_drawer then
        let tokens = Signal.map (function
          | "black" -> [ "background", View_base.main_background "black" ]
          | _ -> []) dark_theme in
        themed ~tokens_signal:tokens drawer_main
      else drawer_main in
    let shell = application_sidebar model_source send ~width:360 drawer_main in
    if ios_drawer then
      let tokens = Signal.map (function
        | "black" -> [ "background", Lui_ui.Adaptive { light = "#FCFCFC"; dark = "#2C2C2C" } ]
        | _ -> []) dark_theme in
      let welcome =
        overlay ~grow:1.0
          [ authentication_screen context model_source send;
            align `top_trailing (row ~padding:12
              [View_sidebar.sidebar_settings context model_source send]);
            if_
              ~test:(reactive View_base.model_settings_open_ model_source)
              (View_settings.settings_sheet context model_source send) ] in
      stack ~grow:1.0
        [ if_ ~test:(reactive View_base.authentication_screen_visible_ model_source) welcome;
          if_ ~test:(reactive View_base.application_shell_visible_ model_source)
            (themed ~tokens_signal:tokens (box ~grow:1.0 [shell])) ]
    else shell

let application_view (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context <> SwiftUIHost && Lui_ui.host context <> KotlinHost then
    application_drawer_view context model_source send
  else custom @@ fun context parent ->
    let node = Lui_ui.extension context "native-pdf-workspace" in
    attach context parent node;
    Lui_ui.extension_property_signal context node "payload"
      (Signal.map (fun (current : Model.logseq_model) ->
        View_base.string_wire_value (Option.value ~default:"null" current.pdf_workspace)) model_source);
    Lui_ui.on_event context node (function
      | ExtensionEvent (_, _, "event", values) ->
        (match String_map.find_opt "payload" values with
         | Some (StringValue payload) -> ignore (send (Model.PdfWorkspaceEvent payload))
         | _ -> ())
      | _ -> ());
    ignore (mount context ~parent:node (application_drawer_view context model_source send));
    node

let logseq_view context model_source send : t =
  stack ~grow:1.0 [application_view context model_source send;
    View_outliner.task_dates_dialog model_source send;
    View_outliner.composer_task_date_dialog model_source send;
    if_ ~test:(Signal.map (fun (current : Model.logseq_model) -> current.authentication_form.opened) model_source)
      (View_authentication.sheet model_source send)]
