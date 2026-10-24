val outliner_node_icon : Model.logseq_model -> Model.outline_row -> string
val node_icon : Model.logseq_model -> string -> string
val node_icon_view : ?muted:bool -> size:int -> string Signal.signal -> Lui_elements.t
val string_wire_value : string -> Lui_protocol.wire_value
val int_wire_value : int -> Lui_protocol.wire_value
val bool_wire_value : bool -> Lui_protocol.wire_value
val outliner_row_completed_ : Model.outline_row -> bool
val outliner_row_id_wire_value : Model.outline_row -> Lui_protocol.wire_value
val outliner_row_completed_wire_value :
  Model.outline_row -> Lui_protocol.wire_value
val extension_string :
  Lui_protocol.wire_value Lui_protocol.String_map.t ->
  Lui_protocol.String_map.key -> string
val extension_int :
  Lui_protocol.wire_value Lui_protocol.String_map.t ->
  Lui_protocol.String_map.key -> int
val navigation_path_depth : 'a list -> int
val handle_native_navigation_event :
  Lui_protocol.event -> (Model.logseq_action -> bool) -> bool
val handle_native_search_event :
  Lui_protocol.event -> (Model.logseq_action -> bool) -> bool
val handle_outliner_editor_event :
  Lui_protocol.event ->
  string Signal.signal -> (Model.logseq_action -> bool) -> bool
val optional_string : string option -> string
val outliner_row_youtube_target : Model.outline_row -> string
val outliner_row_asset_type : Model.outline_row -> string
val outliner_row_local_path : Model.outline_row -> string
val outliner_row_uuid : Model.outline_row -> string
val request_node_action : Model.logseq_model -> string -> Model.logseq_action
val handle_outliner_block_content_event :
  Lui_protocol.event ->
  Model.logseq_model Signal.signal -> (Model.logseq_action -> bool) -> bool
val graph_label : Model.logseq_model -> string
val sync_label : Model.logseq_model -> string
val sync_indicator_label : Model.logseq_model -> string
val sync_accessibility_identifier : Model.logseq_model -> string
val sync_indicator_foreground : Model.logseq_model -> string
val sync_connection_label : Model.logseq_model -> string
val sync_pending_label : Model.logseq_model -> string
val sync_cursor_label : Model.logseq_model -> string
val active_page_actions_visible_ : Model.logseq_model -> bool
val connection_settings_visible_ : Model.logseq_model -> bool
val active_page_favorite_label : Model.logseq_model -> string
val page_deletion_pending_ : Model.logseq_model -> bool
val sign_out_pending_ : Model.logseq_model -> bool
val sidebar_page_identifier : Model.sidebar_page -> string
val sidebar_page_title : Model.sidebar_page -> string
val sidebar_graph_identifier : Model.graph -> string
val graph_title : Model.graph -> string
val sidebar_graph_selected_ : Model.logseq_model -> Model.graph -> bool
val sidebar_graph_disabled_ : Model.graph -> bool
val favorites_empty_ : Model.logseq_model -> bool
val recent_pages_empty_ : Model.logseq_model -> bool
val sidebar_favorites : Model.logseq_model -> Model.sidebar_page list
val sidebar_recent_pages : Model.logseq_model -> Model.sidebar_page list
val model_task_statuses : Model.logseq_model -> Model.task_status list
val model_outliner_autocomplete_candidates :
  Model.logseq_model -> Model.outliner_autocomplete_candidate list
val model_composer_assets : Model.logseq_model -> Model.composer_asset list
val model_language_choices :
  Model.logseq_model -> Model.settings_language_choice list
val model_community_links :
  Model.logseq_model -> Model.settings_community_link list
val model_graph_menu_open_ : Model.logseq_model -> bool
val model_task_status_picker_open_ : Model.logseq_model -> bool
val model_attachment_picker_open_ : Model.logseq_model -> bool
val model_new_graph_name : Model.logseq_model -> string
val model_new_graph_encrypted_ : Model.logseq_model -> bool
val model_graph_password : Model.logseq_model -> string
val model_graphs : Model.logseq_model -> Model.graph list
val model_settings_language_menu_open_ : Model.logseq_model -> bool
val model_settings_appearance_menu_open_ : Model.logseq_model -> bool
val model_search_loading_ : Model.logseq_model -> bool
val model_search_query : Model.logseq_model -> string
val model_search_open_ : Model.logseq_model -> bool
val model_settings_open_ : Model.logseq_model -> bool
val model_create_graph_open_ : Model.logseq_model -> bool
val model_graph_password_open_ : Model.logseq_model -> bool
val model_sync_details_open_ : Model.logseq_model -> bool
val journals_sidebar_selected_ : Model.logseq_model -> bool
val flashcards_sidebar_selected_ : Model.logseq_model -> bool
val graphs_sidebar_selected_ : Model.logseq_model -> bool
val sidebar_page_selected_ : Model.logseq_model -> Model.sidebar_page -> bool
val sidebar_tab_visible_ : Model.logseq_model -> string -> bool
val flashcards_tab_visible_ : Model.logseq_model -> bool
val graphs_tab_visible_ : Model.logseq_model -> bool
val composer_collapsed_ : Model.logseq_model -> bool
val composer_send_disabled_ : Model.logseq_model -> bool
val task_status_identifier : Model.task_status -> string
val task_status_title : Model.task_status -> string
val task_status_style : Model.task_status -> string
val task_status_icon_name : Model.task_status -> string
val task_status_foreground : Model.task_status -> string
val task_status_selected_ : Model.logseq_model -> bool
val search_result_identifier : Model.search_hit -> string
val search_result_title : Model.search_hit -> string
val search_result_breadcrumb : Model.search_hit -> string
val page_search_results : Model.logseq_model -> Model.search_hit list
val block_search_results : Model.logseq_model -> Model.search_hit list
val page_search_results_present_ : Model.logseq_model -> bool
val block_search_results_present_ : Model.logseq_model -> bool
val search_empty_state_present_ : Model.logseq_model -> bool
val search_results_present_ : Model.logseq_model -> bool
val search_result_status : Model.logseq_model -> string
val search_result_context_present_ : Model.search_hit -> bool
val search_empty_message : Model.logseq_model -> string
val search_empty_supporting_message : string -> string
val outliner_row_identifier : Model.outline_row -> string
val outliner_row_breadcrumbs : Model.outline_row -> Model.sidebar_page list
val outliner_row_tags : Model.outline_row -> Model.sidebar_page list
val outliner_row_action_identifier : Model.outline_row -> string
val outliner_row_title : Model.outline_row -> string
val outliner_row_indent : Model.outline_row -> int
val outliner_row_has_children : Model.outline_row -> bool
val outliner_row_zoom_label : Model.outline_row -> string
val outliner_row_zoom_identifier : Model.outline_row -> string
val outliner_row_action_label :
  Model.logseq_model -> Model.outline_row -> string
val outliner_row_collapse_label : Model.outline_row -> string
val outliner_row_collapse_glyph : Model.outline_row -> string
val outliner_collapse_icon_name : bool -> string
val outliner_collapse_identifier : Model.outline_row -> string
val row_editing_ : Model.logseq_model -> Model.outline_row -> bool
val row_not_editing_ : Model.logseq_model -> Model.outline_row -> bool
val string_vector_contains_ : string list -> string -> bool
val row_selected_ : Model.logseq_model -> Model.outline_row -> bool
val outliner_selection_active_ : Model.logseq_model -> bool
val outliner_selection_inactive_ : Model.logseq_model -> bool
val outliner_editor_active_ : Model.logseq_model -> bool
val outliner_autocomplete_active_ : Model.logseq_model -> bool
val outliner_autocomplete_identifier :
  Model.outliner_autocomplete_candidate -> string
val outliner_autocomplete_label :
  Model.outliner_autocomplete_candidate -> string
val node_navigation_active_ : Model.logseq_model -> bool
val node_navigation_inactive_ : Model.logseq_model -> bool
val journals_destination_ : Model.logseq_model -> bool
val flashcards_destination_ : Model.logseq_model -> bool
val graphs_destination_ : Model.logseq_model -> bool
val graph_selected_ : Model.logseq_model -> bool
val graph_picker_visible_ : Model.logseq_model -> bool
val graph_loading_visible_ : Model.logseq_model -> bool
val graph_loading_message : Model.logseq_model -> string
val selected_graph_local_ : Model.logseq_model -> bool
val journal_route_active_ : Model.logseq_model -> bool
val journal_root_visible_ : Model.logseq_model -> bool
val selected_page_present_ : Model.logseq_model -> bool
val selected_page_absent_ : Model.logseq_model -> bool
val journal_home_visible_ : Model.logseq_model -> bool
val selected_page_visible_ : Model.logseq_model -> bool
val selected_page_models : Model.logseq_model -> Model.logseq_model list
val selected_page_model_key : Model.logseq_model -> string
val journal_tree_retained_ : Model.logseq_model -> bool
val older_journals_visible_ : Model.logseq_model -> bool
val journal_section_marker_for :
  Model.journal_section_marker list ->
  string -> Model.journal_section_marker option
val outliner_journal_marker :
  Model.logseq_model ->
  Model.outline_row -> Model.journal_section_marker option
val outliner_journal_heading_visible_ :
  Model.logseq_model -> Model.outline_row -> bool
val outliner_journal_divider_visible_ :
  Model.logseq_model -> Model.outline_row -> bool
val outliner_journal_title : Model.logseq_model -> Model.outline_row -> string
val outliner_journal_page_id :
  Model.logseq_model -> Model.outline_row -> string
val outliner_journal_button_identifier :
  Model.logseq_model -> Model.outline_row -> string
val outliner_journal_accessibility_label :
  Model.logseq_model -> Model.outline_row -> string
val node_screen_visible_ : Model.logseq_model -> bool
val primary_sidebar_button_visible_ : Model.logseq_model -> bool
val sidebar_drag_disabled_ : Model.logseq_model -> bool
val connection_control_visible_ : Model.logseq_model -> bool
val search_query_present_ : Model.logseq_model -> bool
val bottom_chrome_presentation : Model.logseq_model -> string
val bottom_chrome_selection_ : Model.logseq_model -> bool
val search_editor_active_ : Model.logseq_model -> bool
val bottom_chrome_editor_ : Model.logseq_model -> bool
val bottom_chrome_expanded_composer_ : Model.logseq_model -> bool
val bottom_chrome_capture_and_search_ : Model.logseq_model -> bool
val bottom_chrome_occupies_layout_space_ : Model.logseq_model -> bool
val active_node_projection : Model.logseq_model -> Model.node_projection option
val node_projection_identifier : Model.node_projection -> string
val active_node_uuid : Model.logseq_model -> string
val active_node_breadcrumbs : Model.logseq_model -> Model.sidebar_page list
val active_node_has_breadcrumbs_ : Model.logseq_model -> bool
val active_node_title : Model.logseq_model -> string
val main_title : Model.logseq_model -> string
val outliner_scroll_identity : Model.logseq_model -> string
val current_content_active_ : Model.logseq_model -> bool
val current_content_is_tag_ : Model.logseq_model -> bool
val current_content_is_property_ : Model.logseq_model -> bool
val active_node_page_uuid : Model.logseq_model -> string
val active_node_related_rows : Model.logseq_model -> Model.outline_row list
val active_node_linked_reference_rows :
  Model.logseq_model -> Model.outline_row list
val node_related_section_visible_ : Model.logseq_model -> bool
val node_tag_section_visible_ : Model.logseq_model -> bool
val node_tag_section_empty_ : Model.logseq_model -> bool
val node_linked_reference_section_visible_ : Model.logseq_model -> bool
val page_content_ready_ : Model.logseq_model -> bool
val page_loading_visible_ : Model.logseq_model -> bool
val node_can_add_first_block_ : Model.logseq_model -> bool
val node_outliner_visible_ : Model.logseq_model -> bool
val node_title_visible_ : Model.logseq_model -> bool
val main_can_add_first_block_ : Model.logseq_model -> bool
val main_related_section_visible_ : Model.logseq_model -> bool
val main_tag_section_visible_ : Model.logseq_model -> bool
val main_linked_reference_section_visible_ : Model.logseq_model -> bool
val outliner_row_has_breadcrumb_ : Model.outline_row -> bool
val outliner_row_breadcrumb : Model.outline_row -> string
val outliner_row_structured_breadcrumb_ : Model.outline_row -> bool
val outliner_row_fallback_breadcrumb_ : Model.outline_row -> bool
val breadcrumb_identifier : Model.sidebar_page -> string
val breadcrumb_title : Model.sidebar_page -> string
val editing_title : Model.logseq_model -> string
val editing_caret : Model.logseq_model -> int
val outliner_row_has_status_ : Model.outline_row -> bool
val outliner_row_status_title : Model.outline_row -> string
val outliner_task_status_icon : Model.outline_row -> string
val outliner_task_status_style_is_ : Model.outline_row -> string -> bool
val outliner_task_status_backlog_ : Model.outline_row -> bool
val outliner_task_status_todo_ : Model.outline_row -> bool
val outliner_task_status_doing_ : Model.outline_row -> bool
val outliner_task_status_review_ : Model.outline_row -> bool
val outliner_task_status_done_ : Model.outline_row -> bool
val outliner_task_status_canceled_ : Model.outline_row -> bool
val outliner_editor_task_label : Model.logseq_model -> string
val outliner_row_has_tags_ : Model.outline_row -> bool
val outliner_row_sync_failed_ : Model.outline_row -> bool
val outliner_row_list_item_press_enabled_ :
  Lui_protocol.host_kind -> Model.outline_row -> bool
val outliner_tag_identifier : Model.sidebar_page -> string
val outliner_tag_title : Model.sidebar_page -> string
val outliner_row_journal_ : Model.logseq_model -> Model.outline_row -> bool
val composer_asset_title : Model.composer_asset -> string
val composer_asset_path : Model.composer_asset -> string
val composer_asset_identifier : Model.composer_asset -> string
val composer_asset_is_image : Lui_ui.ui_context -> Model.composer_asset -> bool
val composer_assets_present_ : Model.logseq_model -> bool
val asset_preview_ : Model.logseq_model -> bool
val asset_preview_path : Model.logseq_model -> string
val composer_expanded_ : Model.logseq_model -> bool
val composer_draft : Model.logseq_model -> string
val composer_autofocus_ : Model.logseq_model -> bool
val outliner_task_status_option_identifier : Model.task_status -> string
val first_flashcard : Model.logseq_model -> Model.flashcard option
val flashcards_empty_ : Model.logseq_model -> bool
val flashcards_present_ : Model.logseq_model -> bool
val flashcard_question : Model.logseq_model -> string
val flashcard_remaining_label : Model.logseq_model -> string
val flashcard_show_cloze_ : Model.logseq_model -> bool
val flashcard_show_answer_ : Model.logseq_model -> bool
val flashcard_show_ratings_ : Model.logseq_model -> bool
val visible_flashcard_answer_rows :
  Model.logseq_model -> Model.flashcard_answer_row list
val flashcard_answer_rows_visible_ : Model.logseq_model -> bool
val flashcard_answer_identifier : Model.flashcard_answer_row -> string
val flashcard_answer_text : Model.flashcard_answer_row -> string
val graph_identifier : Model.graph -> string
val graph_delete_identifier : Model.graph -> string
val graph_status_identifier : Model.graph -> string
val graph_status_visible_ : Model.graph -> bool
val graph_status_title : Model.graph -> string
val graph_not_ready_ : Model.graph -> bool
val graph_row_disabled_ : Model.logseq_model -> Model.graph -> bool
val graph_delete_active_ : Model.logseq_model -> Model.graph -> bool
val graph_row_local_ : Model.logseq_model -> Model.graph -> bool
val graph_icon_name : bool -> Model.graph -> string
val sidebar_graph_icon_name : Model.logseq_model -> Model.graph -> string
val local_graphs : Model.logseq_model -> Model.graph list
val remote_graphs : Model.logseq_model -> Model.graph list
val shared_graphs : Model.logseq_model -> Model.graph list
val shared_graphs_present_ : Model.logseq_model -> bool
val local_graphs_empty_ : Model.logseq_model -> bool
val graphs_empty_ : Model.logseq_model -> bool
val graphs_present_ : Model.logseq_model -> bool
val remote_graphs_present_ : Model.logseq_model -> bool
val new_graph_name_empty_ : Model.logseq_model -> bool
val graph_create_disabled_ : Model.logseq_model -> bool
val empty_graphs_loading_ : Model.logseq_model -> bool
val empty_graphs_refreshable_ : Model.logseq_model -> bool
val graph_deletion_pending_ : Model.logseq_model -> bool
val graph_deletion_message : Model.logseq_model -> string
val graph_password_empty_ : Model.logseq_model -> bool
val graph_unlock_disabled_ : Model.logseq_model -> bool
val effect_error_present_ : Model.logseq_model -> bool
val effect_error_message : Model.logseq_model -> string
val graph_unlock_error_present_ : Model.logseq_model -> bool
val graph_unlock_error_message : Model.logseq_model -> string
val global_effect_error_present_ : Model.logseq_model -> bool
val graph_picker_error_reason : Model.logseq_model -> string option
val graph_picker_error_present_ : Model.logseq_model -> bool

val graphs_screen_error_visible_ : Model.logseq_model -> bool
val error_separator : string -> int
val graph_picker_error_code : Model.logseq_model -> string
val graph_picker_error_title : Model.logseq_model -> string
val graph_picker_error_message : Model.logseq_model -> string
val settings_main_visible_ : Model.logseq_model -> bool
val settings_spell_check : Model.logseq_model -> bool
val settings_auto_correction : Model.logseq_model -> bool
val settings_base_url : Model.logseq_model -> string
val settings_base_url_invalid_ : Model.logseq_model -> bool
val settings_apply_disabled_ : Model.logseq_model -> bool
val settings_version : Model.logseq_model -> string
val settings_revision : Model.logseq_model -> string
val settings_language_title : Model.logseq_model -> string
val settings_appearance_title : Model.logseq_model -> string
val settings_language_choice_title : Model.settings_language_choice -> string
val settings_language_choice_identifier :
  Model.settings_language_choice -> string
val settings_community_link_title : Model.settings_community_link -> string
val settings_community_link_identifier :
  Model.settings_community_link -> string
val settings_community_link_needs_separator_ :
  Model.logseq_model -> Model.settings_community_link -> bool
val settings_tabs_visible_ : Model.logseq_model -> bool
val settings_tab_title : string -> string
val settings_tabs_summary : Model.logseq_model -> string
val runtime_log_visible_ : Model.logseq_model -> bool
val tab_enabled_ : Model.logseq_model -> string -> bool
val tab_toggle_label : Model.logseq_model -> string -> string
val tab_selection_glyph : Model.logseq_model -> string -> string
val tab_selection_icon_name : Model.logseq_model -> string -> string
val tab_selection_foreground : Model.logseq_model -> string -> string
val tab_disabled_ : Model.logseq_model -> string -> bool
val tab_index : Model.logseq_model -> string -> int
val tab_movement_visible_ : Model.logseq_model -> string -> bool
val settings_flashcards_before_graphs_ : Model.logseq_model -> bool
val settings_flashcards_after_graphs_ : Model.logseq_model -> bool
val settings_available_tabs_present_ : Model.logseq_model -> bool
val tab_move_up_disabled_ : Model.logseq_model -> string -> bool
val tab_move_down_disabled_ : Model.logseq_model -> string -> bool
val tab_toggle_identifier : string -> string
val tab_up_identifier : string -> string
val tab_down_identifier : string -> string
val runtime_log_level : Model.runtime_log_record -> string
val runtime_log_timestamp : Model.runtime_log_record -> string
val runtime_log_message : Model.runtime_log_record -> string
val runtime_log_error_ : Model.runtime_log_record -> bool
val runtime_log_empty_ : Model.logseq_model -> bool
val runtime_log_records : Model.logseq_model -> Model.runtime_log_record list
val runtime_log_record_identifier : Model.runtime_log_record -> string
val runtime_log_errors_label : Model.logseq_model -> string
val runtime_log_order_label : Model.logseq_model -> string
val runtime_log_source_label : Model.logseq_model -> string
val sync_error_present_ : Model.logseq_model -> bool
val sync_error_message : Model.logseq_model -> string
val selected_page_content_title_visible_ : Model.logseq_model -> bool
val selected_page_title : Model.logseq_model -> string
val navigation_root_model : Model.logseq_model -> Model.logseq_model
val journal_navigation_model : Model.logseq_model -> Model.logseq_model
val node_route_model :
  active:bool -> Model.logseq_model -> Model.node_projection -> Model.logseq_model
val app_navigation_depth : Model.logseq_model -> int
val app_back_depth : Model.logseq_model -> int
val search_navigation_depth : Model.logseq_model -> int
val search_node_routes : Model.logseq_model -> Model.node_projection list
val active_route_only : 'a list -> 'a list
val active_app_node_routes : Model.logseq_model -> Model.node_projection list
val active_search_node_routes :
  Model.logseq_model -> Model.node_projection list
val kotlin_app_root_visible_ : Model.logseq_model -> bool
val kotlin_search_root_visible_ : Model.logseq_model -> bool
val authentication_required_ : Model.logseq_model -> bool
val authentication_screen_visible_ : Model.logseq_model -> bool
val graph_picker_screen_visible_ : Model.logseq_model -> bool
val authentication_signing_in_ : Model.logseq_model -> bool
val authentication_error_present_ : Model.logseq_model -> bool
val authentication_error_message : Model.logseq_model -> string
val graph_picker_hidden_ : Model.logseq_model -> bool
val main_screen_visible_ : Model.logseq_model -> bool
val application_shell_visible_ : Model.logseq_model -> bool
val drawer_selected_ : Model.logseq_model -> bool
val drawer_disabled_ : Model.logseq_model -> bool
val with_label : string -> Lui_elements.t -> Lui_elements.t
val with_label_signal :
  string Signal.signal -> Lui_elements.t -> Lui_elements.t
val with_selected_signal :
  bool Signal.signal -> Lui_elements.t -> Lui_elements.t
val with_string_prop :
  Lui_protocol.Property_map.key -> string -> Lui_elements.t -> Lui_elements.t
val with_string_prop_signal :
  Lui_protocol.Property_map.key ->
  string Signal.signal -> Lui_elements.t -> Lui_elements.t
val with_bool_prop_signal :
  Lui_protocol.Property_map.key ->
  bool Signal.signal -> Lui_elements.t -> Lui_elements.t
val with_int_prop_signal :
  Lui_protocol.Property_map.key ->
  int Signal.signal -> Lui_elements.t -> Lui_elements.t
val with_float_prop_signal :
  Lui_protocol.Property_map.key ->
  float Signal.signal -> Lui_elements.t -> Lui_elements.t

val with_liquid_glass : string -> Lui_elements.t -> Lui_elements.t
val with_reading_insets : Lui_elements.t -> Lui_elements.t
val icon_of_wire_name : string -> Lui_elements.icon
val active_node_result_views : Model.logseq_model -> string

val task_priority_icon_name : Model.task_status -> string
