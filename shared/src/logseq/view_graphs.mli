val graph_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  Model.graph Signal.signal ->
  'a -> (Model.logseq_action -> 'b) -> Lui_elements.t
val graph_list_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  Model.graph Signal.signal ->
  bool -> (Model.logseq_action -> 'a) -> Lui_elements.t
val graph_create_sheet :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val graph_delete_dialog :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val graph_picker_overflow_menu : Model.logseq_model Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t
val graph_picker_error_banner :
  Model.logseq_model Signal.signal -> Lui_elements.t
val graph_password_sheet :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val graphs_screen :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val kotlin_graph_picker_loading_state : Model.logseq_model Signal.signal -> unit -> Lui_elements.t
val kotlin_graph_picker_empty_state : Model.logseq_model Signal.signal -> (Model.logseq_action -> bool) -> Lui_elements.t
val kotlin_graph_picker_catalog :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val graph_picker_screen :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
