open Lui_protocol
open Lui_elements

let sidebar_page_row (context : Lui_ui.ui_context) model_source page_source send : t
  =
  let page = sample page_source in
  if Lui_ui.host context = KotlinHost then
    View_base.with_label_signal
      (Signal.map View_base.sidebar_page_title page_source)
      (list_item
      ~text:(reactive View_base.sidebar_page_title page_source)
      ~icon:(`app "document")
      ~selected:(reactive View_base.sidebar_page_selected_ model_source page_source)
      ~accessibility_identifier:(View_base.sidebar_page_identifier page)
      ~on_press:(fun _ ->
        ignore (send (Model.SelectSidebarPage (sample page_source).uuid)))
      [])
  else
    View_base.with_label_signal
      (Signal.map View_base.sidebar_page_title page_source)
      (list_item
      ~text:(reactive View_base.sidebar_page_title page_source)
      ~role:`navigation ~icon:(`app "document")
      ~selected:(reactive View_base.sidebar_page_selected_ model_source page_source)
      ~accessibility_identifier:(View_base.sidebar_page_identifier page)
      ~on_press:(fun _ ->
        ignore (send (Model.SelectSidebarPage (sample page_source).uuid)))
      [])

let sidebar_graph_menu_item model_source graph_source send : t =
 fun context parent ->
  let graph = sample graph_source in
  View_base.with_string_prop_signal InlineIconName
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
       [])) context parent

let sidebar_graph_menu_items model_source send =
  [ keyed
      ~source:(Signal.map View_base.model_graphs model_source)
      ~key:View_base.sidebar_graph_identifier ~cmp:compare
      ~mount:(fun graph_source ->
        sidebar_graph_menu_item model_source graph_source send) ]

let sidebar_section_heading title icon : t =
  column ~gap:0
    [
      box ~height:16 [];
      row ~gap:6 ~cross:`center ~padding_horizontal:12
        [
          Lui_elements.icon ~name:icon ~width:14 ~height:14
            ~foreground:"muted-foreground" [];
          text ~style_class:"caption semibold" ~foreground:"muted-foreground"
            ~value:title [];
        ];
      box ~height:6 [];
    ]

let sidebar_empty_section_label title : t =
  column ~gap:0
    [
      row ~padding_horizontal:12
        [
          text ~style_class:"caption" ~foreground:"muted-foreground"
            ~value:title [];
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

let sidebar_graph_switch (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    View_base.with_label "Switch graph"
      (list_item
         ~accessibility_identifier:"button.graph-switch"
         ~on_press:(press send Model.OpenGraphMenu)
         [ sidebar_graph_switch_content model_source ])
  else
    View_base.with_label "Switch graph"
      (button ~variant:`ghost ~grow:1.0 ~min_height:44
      ~text_signal:(Signal.map View_base.graph_label model_source)
      ~text_alignment:`start ~style_class:"semibold" ~foreground:"foreground"
      ~icon:(`app "chevron-down") ~icon_placement:`trailing
      ~accessibility_identifier:"button.graph-switch"
      [context_menu ~accessibility_identifier:"menu.graph-switch"
         (sidebar_graph_menu_items model_source send)])

let sidebar_journals_row (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    View_base.with_label "Journals"
      (list_item ~icon:(`app "calendar")
      ~selected:(reactive View_base.journals_sidebar_selected_ model_source)
      ~accessibility_identifier:"link.sidebar.journals"
      ~on_press:(press send Model.ShowJournals)
      ~text:"Journals" [])
  else
    View_base.with_label "Journals"
      (list_item ~role:`navigation ~icon:(`app "calendar")
      ~selected:(reactive View_base.journals_sidebar_selected_ model_source)
      ~accessibility_identifier:"link.sidebar.journals"
      ~on_press:(press send Model.ShowJournals)
      ~text:"Journals" [])

let sidebar_flashcards_row (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    View_base.with_label "Flashcards"
      (list_item ~icon:(`app "flashcards")
      ~selected:(reactive View_base.flashcards_sidebar_selected_ model_source)
      ~accessibility_identifier:"link.sidebar.flashcards"
      ~on_press:(press send Model.ShowFlashcards)
      ~text:"Flashcards" [])
  else
    View_base.with_label "Flashcards"
      (list_item ~role:`navigation ~icon:(`app "flashcards")
      ~selected:(reactive View_base.flashcards_sidebar_selected_ model_source)
      ~accessibility_identifier:"link.sidebar.flashcards"
      ~on_press:(press send Model.ShowFlashcards)
      ~text:"Flashcards" [])

let sidebar_graphs_row (context : Lui_ui.ui_context) model_source send : t =
  if Lui_ui.host context = KotlinHost then
    View_base.with_label "Graphs"
      (list_item ~icon:(`app "folder")
      ~selected:(reactive View_base.graphs_sidebar_selected_ model_source)
      ~accessibility_identifier:"link.sidebar.graphs"
      ~on_press:(press send Model.ShowGraphs)
      ~text:"Graphs" [])
  else
    View_base.with_label "Graphs"
      (list_item ~role:`navigation ~icon:(`app "folder")
      ~selected:(reactive View_base.graphs_sidebar_selected_ model_source)
      ~accessibility_identifier:"link.sidebar.graphs"
      ~on_press:(press send Model.ShowGraphs)
      ~text:"Graphs" [])

let sidebar_view (context : Lui_ui.ui_context) model_source send : t =
  column ~accessibility_identifier:"sidebar.navigation" ~grow:1.0 ~gap:4
    ~padding:12
    [
      box
        ~height:(if Lui_ui.host context = KotlinHost then 8 else 48)
        [];
      row ~cross:`center ~gap:4
        [
          stack ~grow:1.0
            [
              sidebar_graph_switch context model_source send;
              if_
                ~test:(Signal.map (fun current -> Lui_ui.host context = KotlinHost
                  && View_base.model_graph_menu_open_ current) model_source)
                (dropdown_menu ~anchor:`below ~anchor_alignment:`start
                   ~min_width:240 ~accessibility_identifier:"menu.graph-switch"
                   ~style_class:"anchored-popover" ~gap:0
                   ~on_dismiss:(press send Model.DismissGraphMenu)
                   (sidebar_graph_menu_items model_source send));
            ];
          button ~icon:(`app "settings") ~variant:`ghost ~size:`icon
            ~width:44 ~height:44 ~label:"Settings"
            ~accessibility_identifier:"button.sidebar.settings"
            ~on_press:(press send Model.OpenSettings) [];
        ];
      box ~height:12 [];
      sidebar_journals_row context model_source send;
      if_
        ~test:(Signal.map View_base.flashcards_tab_visible_ model_source)
        (sidebar_flashcards_row context model_source send);
      if_
        ~test:(Signal.map View_base.graphs_tab_visible_ model_source)
        (sidebar_graphs_row context model_source send);
      scroll ~grow:1.0 ~accessibility_identifier:"scroll.sidebar.pages"
        [
          column ~gap:4
            [
              column ~accessibility_identifier:"section.sidebar.favorites"
                ~gap:2
                [
                  sidebar_section_heading "Favorites" (`app "star");
                  if_
                    ~test:(Signal.map View_base.favorites_empty_ model_source)
                    (sidebar_empty_section_label "No favorites yet");
                  keyed
                    ~source:
                      (Signal.map View_base.sidebar_favorites model_source)
                    ~key:View_base.sidebar_page_identifier ~cmp:compare
                    ~mount:(fun page_source ->
                       sidebar_page_row context model_source page_source
                         send);
                ];
              column ~accessibility_identifier:"section.sidebar.recent"
                ~gap:2
                [
                  sidebar_section_heading "Recent" (`app "history");
                  if_
                    ~test:
                      (Signal.map View_base.recent_pages_empty_ model_source)
                    (sidebar_empty_section_label "No recent pages");
                  keyed
                    ~source:
                      (Signal.map View_base.sidebar_recent_pages model_source)
                    ~key:View_base.sidebar_page_identifier ~cmp:compare
                    ~mount:(fun page_source ->
                       sidebar_page_row context model_source page_source
                         send);
                ];
            ];
        ];
    ]
