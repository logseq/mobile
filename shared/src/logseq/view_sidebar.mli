val sidebar_page_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  Model.sidebar_page Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val sidebar_graph_menu_item :
  Model.logseq_model Signal.signal ->
  Model.graph Signal.signal -> (Model.logseq_action -> 'a) -> Lui_elements.t
val sidebar_section_heading : string -> Lui_elements.icon -> Lui_elements.t
val sidebar_empty_section_label : string -> Lui_elements.t
val sidebar_graph_switch_content :
  Model.logseq_model Signal.signal -> Lui_elements.t
val sidebar_graph_switch :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val sidebar_journals_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val sidebar_flashcards_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val sidebar_graphs_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val sidebar_view :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
