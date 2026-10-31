val composer_attachment_button : Model.logseq_model Signal.signal -> Lui_ui.ui_context -> (Model.logseq_action -> bool) -> Lui_elements.t
val composer_task_status_button :
  Lui_ui.ui_context -> Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val composer_asset_preview :
  Lui_ui.ui_context -> Model.composer_asset Signal.signal -> Lui_elements.t
val composer_asset_view : Model.logseq_model Signal.signal -> Lui_ui.ui_context ->
  Model.composer_asset Signal.signal ->
  (Model.logseq_action -> 'a) ->
  Lui_elements.t
val task_status_row :
  Model.logseq_model Signal.signal ->
  Model.task_status Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val composer_view :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val outliner_task_status_row :
  Model.outline_row Signal.signal ->
  Model.task_status Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
