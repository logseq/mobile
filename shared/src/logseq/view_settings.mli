val settings_language_choice_radio :
  Model.logseq_model Signal.signal ->
  Model.settings_language_choice Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.radio_el
val settings_language_choice_menu_item :
  Model.settings_language_choice Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val settings_language_control :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val settings_appearance_control :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val settings_community_link_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  Model.settings_community_link Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val runtime_log_row :
  Model.runtime_log_record Signal.signal -> Lui_elements.t
val settings_tab_row :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  string -> string -> (Model.logseq_action -> 'a) -> Lui_elements.t
val settings_tabs_screen :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> 'a) -> Lui_elements.t
val runtime_log_toolbar :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val runtime_log_screen :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val settings_toggle_spell_check :
  (Model.logseq_action -> 'a) -> Lui_protocol.event -> unit
val settings_toggle_auto_correction :
  (Model.logseq_action -> 'a) -> Lui_protocol.event -> unit
val settings_general_card :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val settings_editor_card : Model.logseq_model Signal.signal -> Lui_ui.ui_context ->
  bool Signal.signal ->
  bool Signal.signal -> (Model.logseq_action -> 'a) -> Lui_elements.t
val settings_export_row : Model.logseq_model Signal.signal -> Lui_ui.ui_context -> (Model.logseq_action -> bool) -> Lui_elements.t
val settings_runtime_log_row : Model.logseq_model Signal.signal -> Lui_ui.ui_context -> (Model.logseq_action -> bool) -> Lui_elements.t
val sign_in_label : Model.logseq_model Signal.signal -> Lui_elements.t
val settings_sign_out_row : Model.logseq_model Signal.signal -> Lui_ui.ui_context -> (Model.logseq_action -> bool) -> Lui_elements.t
val settings_screen :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val settings_tabs_sheet :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val runtime_log_actions : Model.logseq_model Signal.signal -> Lui_ui.ui_context -> (Model.logseq_action -> bool) -> Lui_elements.t
val runtime_log_sheet :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val settings_main_sheet :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val settings_sheet :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
val page_delete_dialog : Model.logseq_model Signal.signal -> Lui_ui.ui_context -> (Model.logseq_action -> bool) -> Lui_elements.t
val sign_out_dialog : Model.logseq_model Signal.signal -> Lui_ui.ui_context -> (Model.logseq_action -> bool) -> Lui_elements.t
val sync_status_sheet :
  Lui_ui.ui_context ->
  Model.logseq_model Signal.signal ->
  (Model.logseq_action -> bool) -> Lui_elements.t
