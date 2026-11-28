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
  (Model.logseq_action -> 'a) -> Lui_elements.dropdown_menu_item_el
val comment_input :
  Model.logseq_model Signal.signal ->
  autofocus:bool -> text_signal:string Signal.signal -> disabled_signal:bool Signal.signal ->
  on_input:(string -> unit) -> on_submit:(unit -> unit) -> Lui_elements.t
val bot_input :
  Model.logseq_model Signal.signal ->
  placeholder:string Signal.signal -> label:string -> actions:Lui_elements.t list ->
  text_signal:string Signal.signal -> autofocus_signal:bool Signal.signal -> send_label:string Signal.signal ->
  disabled_signal:bool Signal.signal -> on_input:(string -> unit) -> on_send:(unit -> unit) ->
  Lui_elements.t
val composer_view :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val outliner_task_status_row :
  Model.outline_row Signal.signal ->
  Model.task_status Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.dropdown_menu_item_el
val outliner_task_status_context_row :
  Model.outline_row Signal.signal ->
  Model.task_status Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.context_menu_item_el
