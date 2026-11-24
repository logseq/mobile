open Lui_protocol
open Lui_elements

let uses_native_sidebar context =
  Lui_ui.platform context = IOS && Lui_ui.host context = SwiftUIHost

let with_sidebar_selection context selected item =
  if uses_native_sidebar context then
    custom (fun context parent ->
      let node = Lui_ui.platform_tweak context "sidebar-current-item" in
      Lui_ui.extension_property_signal context node "current" (Signal.map View_base.bool_wire_value selected);
      ignore (mount context ~parent:node item);
      attach context parent node;
      node)
  else View_base.with_selected_signal selected item

let sidebar_page_row (context : Lui_ui.ui_context) model_source
    (page_source : Model.sidebar_page Signal.signal) send : t
  =
  let page = sample page_source in
  let navigate _ =
    ignore (send (Model.SelectSidebarPage (sample page_source).uuid)) in
  let icon_source = Signal.map2 (fun current (page : Model.sidebar_page) ->
    View_base.node_icon current page.uuid) model_source page_source in
  let ios = uses_native_sidebar context in
  let selected = Signal.map2 View_base.sidebar_page_selected_ model_source page_source in
  let item custom =
    with_sidebar_selection context selected
      (View_base.with_label_signal (Signal.map View_base.sidebar_page_title page_source)
      (list_item ~corner_radius:10
        ?height:(if Lui_ui.host context = KotlinHost then Some 48 else None)
        ?min_height:(if ios then Some 44 else None)
        ?padding_vertical:(if Lui_ui.host context = KotlinHost then Some 0 else None)
        ~text_signal:(Signal.map (fun page -> if custom then "" else View_base.sidebar_page_title page) page_source)
        ?role:(if Lui_ui.host context = KotlinHost then None else Some `navigation)
        ?icon:(if custom then None else Some (`app "document"))
        ~accessibility_identifier:(View_base.sidebar_page_identifier page)
        ~on_press:navigate
        (if custom then [row ~gap:10 ~cross:`center [
          View_base.node_icon_view ~muted:true ~size:20 icon_source;
          text ?font_family:(if ios then Some "system-ui" else None)
            ~value:(reactive View_base.sidebar_page_title page_source) []]] else []))) in
  column ~gap:0 [
    if_ ~test:(Signal.map (fun icon -> icon <> "") icon_source) (item true);
    if_ ~test:(Signal.map (fun icon -> icon = "") icon_source) (item false)]

let sidebar_graph_menu_item model_source graph_source send : t =
 custom (fun context parent ->
  let graph = sample graph_source in
  mount context ?parent
    (View_base.with_string_prop_signal InlineIconName
      (Signal.map2 View_base.sidebar_graph_icon_name model_source
         graph_source)
      (View_base.with_selected_signal
         (Signal.map2 View_base.sidebar_graph_selected_ model_source
            graph_source)
         (menu_item ?size:(if Lui_ui.host context = KotlinHost then Some `sm else None)
         ~text:(reactive View_base.graph_title graph_source)
         ~disabled:(reactive View_base.sidebar_graph_disabled_ graph_source)
         ~accessibility_identifier:(View_base.sidebar_graph_identifier graph)
         ~on_press:(fun _ ->
           ignore (send (Model.SelectSidebarGraph (sample graph_source).id)))
         []))))

let sidebar_graph_menu_items keyed item model_source send =
  [ keyed
      ~source:(Signal.map View_base.model_graphs model_source)
      ~key:View_base.sidebar_graph_identifier ~cmp:compare
      ~mount:(fun graph_source ->
        item model_source graph_source send) ]

let sidebar_graph_context_item model_source graph_source send =
  let graph = sample graph_source in
  context_menu_item
    ~icon:(reactive (fun model graph -> View_base.icon_of_wire_name (View_base.sidebar_graph_icon_name model graph)) model_source graph_source)
    ~selected:(reactive View_base.sidebar_graph_selected_ model_source graph_source)
    ~text:(reactive View_base.graph_title graph_source)
    ~disabled:(reactive View_base.sidebar_graph_disabled_ graph_source)
    ~accessibility_identifier:(View_base.sidebar_graph_identifier graph)
    ~on_press:(fun () -> ignore (send (Model.SelectSidebarGraph (sample graph_source).id))) ()

let sidebar_graph_dropdown_item model_source graph_source send =
  let graph = sample graph_source in
  dropdown_menu_item ~size:`sm
    ~icon:(reactive (fun model graph -> View_base.icon_of_wire_name (View_base.sidebar_graph_icon_name model graph)) model_source graph_source)
    ~selected:(reactive View_base.sidebar_graph_selected_ model_source graph_source)
    ~text:(reactive View_base.graph_title graph_source)
    ~disabled:(reactive View_base.sidebar_graph_disabled_ graph_source)
    ~accessibility_identifier:(View_base.sidebar_graph_identifier graph)
    ~on_press:(fun () -> ignore (send (Model.SelectSidebarGraph (sample graph_source).id))) []

let sidebar_section_heading model_source title icon : t =
  column ~gap:0
    [
      box ~height:16 [];
      row ~gap:6 ~cross:`center ~padding_horizontal:12
        [
          Lui_elements.icon ~name:icon ~width:14 ~height:14
            ~foreground:"muted-foreground" [];
          text ~style_class:"caption semibold" ~foreground:"muted-foreground"
            ~value:(View_base.tr (Signal.sample model_source) title) [];
        ];
      box ~height:6 [];
    ]

let sidebar_empty_section_label model_source title : t =
  column ~gap:0
    [
      row ~padding_horizontal:12
        [
          text ~style_class:"caption" ~foreground:"muted-foreground"
            ~value:(View_base.tr (Signal.sample model_source) title) [];
        ];
      box ~height:6 [];
    ]

let sidebar_graph_switch_content model_source : t =
  row ~grow:1.0 ~main:`space_between ~cross:`center
    [
      text ~value:(reactive View_base.graph_label model_source) [];
      Lui_elements.icon ~name:(`app "chevron-down") ~width:18 ~height:18
        ~foreground:"muted-foreground" [];
    ]

let native_graph_switch ?grow ?(min_height = 44) ?(foreground = "foreground") ?(compact = false) model_source send : t =
  View_base.with_label_signal
    (Signal.map (fun current ->
       View_base.graph_label current ^ ", " ^ View_base.tr current "Switch graph") model_source)
    (button ~variant:`ghost ~min_height ?grow
      ?width:(if compact then Some 44 else None)
      ~text:(reactive (fun current -> if compact then "" else View_base.graph_label current) model_source)
      ~disabled_signal:(Signal.map View_base.outliner_selection_active_ model_source)
      ~style_class:"semibold" ~foreground
      ~icon:(`app (if compact then "folder" else "chevron-down")) ~icon_placement:`trailing
      ~accessibility_identifier:"button.graph-switch"
      [context_menu ~accessibility_identifier:"menu.graph-switch"
         (sidebar_graph_menu_items keyed_context_menu_item sidebar_graph_context_item model_source send)])

let sidebar_graph_switch (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    View_base.with_label "Switch graph"
      (list_item
         ~accessibility_identifier:"button.graph-switch"
         ~on_press:(press send Model.OpenGraphMenu)
         [ sidebar_graph_switch_content model_source ])
  else native_graph_switch ~grow:1.0 model_source send

let sidebar_destination_row ?(icon_size = 22) context model_source send ~title ~id ~icon ~selected ~action : t =
  let value = View_base.tr (Signal.sample model_source) title in
  let ios = uses_native_sidebar context in
  with_sidebar_selection context (Signal.map selected model_source)
    (View_base.with_label (if ios then value else title)
    (list_item ~corner_radius:10
      ?role:(if Lui_ui.host context = KotlinHost then None else Some `navigation)
      ?min_height:(if ios then Some 48 else None)
      ?icon:(if ios then None else Some icon)
      ?text:(if ios then None else Some value)
      ~accessibility_identifier:("link.sidebar." ^ id)
      ~on_press:(press send action)
      (if ios then [row ~gap:12 ~cross:`center [
        row ~width:28 ~height:28 ~main:`center ~cross:`center [
          Lui_elements.icon ~name:icon ~width:icon_size ~height:icon_size ~foreground:"foreground" [];
        ];
        text ~value ~font_family:"system-ui" ~font_size:"21" ~font_weight:500
          ~style_class:"single-line" [];
      ]] else [])))

let sidebar_journals_row context model_source send =
  sidebar_destination_row context model_source send ~title:"Journals" ~id:"journals"
    ~icon:(`app "calendar") ~selected:View_base.journals_sidebar_selected_ ~action:Model.ShowJournals

let sidebar_flashcards_row context model_source send =
  (* The stacked-card artwork has more inset than the other navigation glyphs. *)
  sidebar_destination_row ~icon_size:28 context model_source send ~title:"Flashcards" ~id:"flashcards"
    ~icon:(`app "flashcards") ~selected:View_base.flashcards_sidebar_selected_ ~action:Model.ShowFlashcards

let sidebar_graphs_row context model_source send =
  sidebar_destination_row context model_source send ~title:"Graphs" ~id:"graphs"
    ~icon:(`app "folder") ~selected:View_base.graphs_sidebar_selected_ ~action:Model.ShowGraphs

let sidebar_view (context : Lui_ui.ui_context) model_source send : t =
  let native_sidebar = uses_native_sidebar context in
  let settings =
    View_base.with_liquid_glass "circle"
      (icon_button ~icon:(`app "settings") ~variant:`ghost ~size:`icon
        ?foreground:(if native_sidebar then Some "foreground" else None)
        ~width:44 ~height:44 ~label:(View_base.tr (Signal.sample model_source) "Settings")
        ~accessibility_identifier:"button.sidebar.settings"
        ~on_press:(press send Model.OpenSettings) []) in
  let header =
    [box ~height:(if Lui_ui.host context = KotlinHost then 8 else 48) [];
      row ~cross:`center ~gap:4
        [
          stack ~grow:1.0
            [
              sidebar_graph_switch context model_source send;
              if_
                ~test:(Signal.map (fun current -> Lui_ui.host context = KotlinHost
                  && View_base.model_graph_menu_open_ current) model_source)
                (dropdown_menu_view (dropdown_menu
                   ~target:(Menu_anchor { side = `below; align = `start; offset = 0. })
                   ~min_width:240 ~accessibility_identifier:"menu.graph-switch"
                   ~style_class:"anchored-popover" ~gap:0
                   ~on_dismiss:(press send Model.DismissGraphMenu)
                   (sidebar_graph_menu_items keyed_dropdown_menu_item sidebar_graph_dropdown_item model_source send)));
            ];
          settings;
        ];
      box ~height:12 []] in
  let section_heading title icon =
    if native_sidebar then
      column ~gap:0 [
        box ~height:18 [];
        row ~padding_horizontal:12 [
          text ~value:(View_base.tr (Signal.sample model_source) title)
            ~font_family:"system-ui" ~font_weight:500 [];
        ];
        box ~height:6 [];
      ]
    else sidebar_section_heading model_source title icon in
  let empty_section title =
    if native_sidebar then
      row ~padding_horizontal:12 [text ~font_family:"system-ui" ~font_size:"15"
        ~foreground:"muted-foreground" ~value:(View_base.tr (Signal.sample model_source) title) []]
    else sidebar_empty_section_label model_source title in
  let pages =
    column ~gap:(if native_sidebar then 2 else 4)
      [
        column ~accessibility_identifier:"section.sidebar.favorites"
          ~gap:(if native_sidebar then 1 else 2)
          [
            section_heading "Favorites" (`app "star");
            if_
              ~test:(Signal.map View_base.favorites_empty_ model_source)
              (empty_section "No favorites yet");
            keyed
              ~source:
                (Signal.map View_base.sidebar_favorites model_source)
              ~key:View_base.sidebar_page_identifier ~cmp:compare
              ~mount:(fun page_source ->
                 sidebar_page_row context model_source page_source
                   send);
          ];
        column ~accessibility_identifier:"section.sidebar.recent"
          ~gap:(if native_sidebar then 1 else 2)
          [
            section_heading "Recent" (`app "history");
            if_
              ~test:
                (Signal.map View_base.recent_pages_empty_ model_source)
              (empty_section "No recent pages");
            keyed
              ~source:
                (Signal.map View_base.sidebar_recent_pages model_source)
              ~key:View_base.sidebar_page_identifier ~cmp:compare
              ~mount:(fun page_source ->
                 sidebar_page_row context model_source page_source
                   send);
          ];
      ] in
  let pages =
    if native_sidebar then pages
    else scroll ~grow:1.0 ~accessibility_identifier:"scroll.sidebar.pages" [pages] in
  let content =
    column ~accessibility_identifier:(if native_sidebar then "sidebar.content" else "sidebar.navigation")
      ~grow:1.0 ~gap:(if native_sidebar then 2 else 4) ~padding:(if native_sidebar then 16 else 12)
      ((if native_sidebar then [] else header) @ [
      sidebar_journals_row context model_source send;
      if_
        ~test:(Signal.map View_base.flashcards_tab_visible_ model_source)
        (sidebar_flashcards_row context model_source send);
      if_
        ~test:(Signal.map View_base.graphs_tab_visible_ model_source)
        (sidebar_graphs_row context model_source send);
      pages;
    ]) in
  if native_sidebar then
    box ~accessibility_identifier:"sidebar.navigation" ~grow:1.0
      [custom (fun context parent ->
          let node = Lui_ui.extension context "native-sidebar" in
          attach context parent node;
          mount_children context node [content; settings];
          node)]
  else content
