val outliner_editor_view :
  Model.logseq_model Signal.signal ->
  string Signal.signal ->
  string Signal.signal ->
  int Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t
val outliner_rich_block_view :
  Model.logseq_model Signal.signal ->
  string Signal.signal ->
  string Signal.signal ->
  string Signal.signal ->
  bool Signal.signal ->
  Model.outline_row Signal.signal ->
  string Signal.signal ->
  string Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t
val outliner_collapse_button :
  Lui_ui.ui_context ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_indent_view : int Signal.signal -> Lui_elements.t
val breadcrumb_button :
  Model.sidebar_page Signal.signal ->
  bool -> (Model.logseq_action -> 'a) -> Lui_elements.t
val node_breadcrumb_button :
  Model.logseq_model Signal.signal ->
  Model.sidebar_page Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val node_breadcrumbs :
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val related_row_breadcrumbs :
  Model.logseq_model Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_tag :
  Model.sidebar_page Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_zoom_control :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> 'a) -> bool -> Lui_elements.t
val outliner_status_icon :
  string ->
  (Model.outline_row -> bool) -> Lui_elements.icon -> Model.outline_row Signal.signal -> Lui_elements.t
val outliner_status_control :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_row_main_content :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val outliner_row_content :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> bool) -> bool -> Lui_elements.t
val outliner_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val outliner_entry :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  View_rows.retained_row Signal.signal ->
  Model.outline_row Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val outliner_entries :
  Lui_ui.ui_context -> Model.logseq_model Signal.signal ->
  source:View_rows.retained_row list Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val toolbar_button :
  Lui_elements.icon ->
  string -> string -> string -> (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_selection_toolbar :
  Lui_ui.ui_context -> Model.logseq_model Signal.signal -> (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_autocomplete_row :
  Lui_ui.ui_context ->
  node_labels:bool ->
  Model.outliner_autocomplete_candidate Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_autocomplete_bar :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val outliner_editor_toolbar :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val node_related_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  source:Model.outline_row Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val related_section_heading : string -> Lui_elements.t
val page_loading_view : Model.logseq_model Signal.signal -> Lui_elements.t

val node_screen :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val node_properties : ?root:bool -> Lui_ui.ui_context -> Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
