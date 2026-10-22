type sync_state =
  | OfflineState
  | SyncingState
  | SyncedState
  | FailedState of string

type navigation_route =
  | NodeRoute of string

type primary_destination =
  | JournalsDestination
  | FlashcardsDestination
  | GraphsDestination

type composer_asset =
  { uuid : string
  ; title : string
  ; local_path : string
  ; payload : string
  }

type asset_preview =
  { preview_title : string
  ; preview_path : string
  }

type ui_session =
  { graph_id : string option
  ; destination : primary_destination
  ; assets : composer_asset list
  ; composer_expanded : bool
  ; search_open : bool
  ; query : string
  ; app_path : navigation_route list
  ; search_path : navigation_route list
  ; selected_page_id : string option
  ; settings_open : bool
  ; recent_graph_ids : string list
  }

type sidebar_page =
  { uuid : string
  ; title : string
  }

type graph =
  { id : string
  ; name : string
  ; is_encrypted : bool
  ; is_ready : bool
  ; role : string option
  }

type task_status =
  { uuid : string
  ; ident : string option
  ; title : string
  ; icon_type : string option
  ; icon_id : string option
  ; icon_color : string option
  }

type settings_projection =
  { appearance : string
  ; language : string
  ; spell_check : bool
  ; auto_correction : bool
  ; sidebar_tabs : string list
  ; base_url : string
  ; version : string
  ; revision : string
  }

type settings_language_choice =
  { id : string
  ; title : string
  }

type settings_community_link =
  { id : string
  ; title : string
  ; url : string
  }

type runtime_log_record =
  { id : string
  ; level : string
  ; source : string
  ; timestamp : string
  ; message : string
  }

type flashcard_answer_row =
  { answer_uuid : string
  ; answer_index : int
  ; answer_text : string
  }

type flashcard =
  { flashcard_uuid : string
  ; question_hidden : string
  ; question_revealed : string
  ; answer_rows : flashcard_answer_row list
  ; has_cloze : bool
  }

type search_hit =
  { hit_uuid : string
  ; hit_title : string
  ; breadcrumb : string
  ; breadcrumbs : sidebar_page list
  ; is_page : bool
  }

type outline_row =
  { row_uuid : string
  ; row_loaded : bool
  ; row_title : string
  ; markup_json : string
  ; query_json : string
  ; youtube_target_url : string option
  ; row_breadcrumb : string
  ; row_breadcrumbs : sidebar_page list
  ; opens_as_page : bool
  ; depth : int
  ; has_children : bool
  ; is_collapsed : bool
  ; is_asset : bool
  ; asset_type : string option
  ; local_path : string option
  ; row_priority : task_status option
  ; row_status : task_status option
  ; tags : sidebar_page list
  ; sync_status : string option
  ; page_id : string
  ; journal_title : string option
  ; journal_day : int option
  }

type sidebar_projection =
  { favorites : sidebar_page list
  ; recent_pages : sidebar_page list
  ; selected_page : sidebar_page option
  ; selected_page_is_tag : bool
  ; selected_page_is_property : bool
  ; result_views_json : string
  ; properties_json : string
  ; related_rows : outline_row list
  ; linked_reference_rows : outline_row list
  }

type journal_section_marker =
  { block_id : string
  ; page_id : string
  ; section_title : string
  ; has_divider : bool
  ; start_index : int
  ; end_index : int
  }

type outliner_editing =
  { editing_uuid : string
  ; editing_title : string
  ; caret_utf16_offset : int
  }

type outliner_autocomplete_kind =
  | NodeAutocomplete
  | TagAutocomplete
  | PropertyAutocomplete

type outliner_autocomplete =
  { autocomplete_kind : outliner_autocomplete_kind
  ; autocomplete_query : string
  }

type outliner_autocomplete_candidate =
  { candidate_index : int
  ; candidate_label : string
  ; candidate_value : string
  }

type node_projection =
  { node_uuid : string
  ; node_page_uuid : string
  ; node_title : string
  ; node_breadcrumbs : sidebar_page list
  ; node_scroll_target : string option
  ; node_is_tag : bool
  ; node_is_property : bool
  ; node_outliner_rows : outline_row list
  ; node_result_views_json : string
  ; node_properties_json : string
  ; node_related_rows : outline_row list
  ; node_linked_reference_rows : outline_row list
  ; node_outliner_editing : outliner_editing option
  ; node_outliner_autocomplete : outliner_autocomplete option
  ; node_outliner_autocomplete_candidates :
      outliner_autocomplete_candidate list
  ; node_outliner_selected_block_ids : string list
  }

type outline_row_splice =
  { splice_start : int option
  ; after_block_id : string option
  ; before_block_id : string option
  ; delete_count : int
  ; splice_rows : outline_row list
  }

type core_projection =
  { graph_name : string option
  ; selected_graph_id : string option
  ; graphs : graph list
  ; is_graph_encrypted : bool
  ; is_graph_unlocked : bool
  ; sidebar : sidebar_projection
  ; task_statuses : task_status list
  ; task_priorities : task_status list
  ; flashcards : flashcard list
  ; sync_connected : bool
  ; applied_server_t : int option
  ; has_pending_semantic_operations : bool
  ; has_pending_sync_request : bool
  ; node_icons : string Lui_protocol.String_map.t
  ; pending_sync_error : string option
  ; is_pending_sync_patch : bool
  ; is_pending_sync_projection : bool
  ; is_graph_catalog_patch : bool
  ; projection_search_query : string
  ; search_offset : int
  ; search_has_more : bool
  ; search_results : search_hit list
  ; reference_update : (string * outline_row list) option
  ; pending_reference_uuid : string option
  ; node_routes : node_projection list
  ; journal_outliner_rows : outline_row list
  ; projection_outliner_editing : outliner_editing option
  ; projection_outliner_autocomplete : outliner_autocomplete option
  ; projection_outliner_autocomplete_candidates :
      outliner_autocomplete_candidate list
  ; projection_outliner_selected_block_ids : string list
  ; outliner_rows : outline_row list
  ; has_older_journals : bool
  ; is_outliner_patch : bool
  ; is_outliner_content_patch : bool
  ; hydrated_rows : outline_row list
  ; is_search_patch : bool
  ; outliner_row_splices : outline_row_splice list
  }

type logseq_effect =
  | ResultViewEffect of int * string * string
  | NodePropertyEffect of int * string * string
  | SendCaptureEffect of int * string
  | SendAssetEffect of int * composer_asset
  | SendTaskEffect of int * string * task_status
  | PersistComposerDraftEffect of int * string
  | PersistUISessionEffect of int * ui_session
  | PresentJournalCalendarEffect of int
  | PresentAttachmentEffect of int * string
  | PresentAssetEffect of int * string * string * string
  | PresentPageShareEffect of int * string * string list
  | SetPageFavoriteEffect of int * string * bool
  | DeletePageEffect of int * string
  | SyncNowEffect of int
  | SyncPendingEffect of int
  | SetOutlinerTaskStatusEffect of int * string * task_status
  | SetOutlinerTaskPriorityEffect of int * string * task_status option
  | SearchNodesEffect of int * string
  | LoadSearchPageEffect of int * string * int
  | LoadPageReferencesEffect of int * string
  | HydrateOutlinerRowsEffect of int * string list
  | TapOutlinerBlockEffect of int * string
  | ChangeOutlinerTextEffect of int * string * string * int
  | ReturnOutlinerEditorEffect of int * string * string * int
  | BackspaceOutlinerEditorEffect of int * string * string * int
  | MoveOutlinerCaretEffect of int * string * int
  | ToggleOutlinerCollapsedEffect of int * string
  | LongPressOutlinerBlockEffect of int * string
  | DropOutlinerBlocksEffect of int * string * string
  | OutlinerToolbarEffect of int * string
  | ChooseOutlinerAutocompleteEffect of int * string
  | ConfirmOutlinerDeleteEffect of int
  | SaveOutlinerEditingEffect of int * string
  | CancelOutlinerEditingEffect of int
  | OpenAppNodeEffect of int * string
  | OpenSearchResultEffect of int * string
  | OpenSearchNodeEffect of int * string
  | CloseAppNodeEffect of int * string
  | CloseSearchNodeEffect of int * string
  | AddRootBlockEffect of int * string
  | SelectSidebarPageEffect of int * string
  | ClearSelectedPageEffect of int
  | LoadOlderJournalsEffect of int
  | LoadFlashcardsEffect of int
  | ReviewFlashcardEffect of int * string * string
  | RefreshGraphsEffect of int
  | OpenGraphEffect of int * string
  | UnlockGraphEffect of int * string
  | CreateGraphEffect of int * string * bool * string
  | DeleteLocalGraphEffect of int * string
  | SaveSettingsEffect of int * settings_projection
  | ExportGraphDatabaseEffect of int
  | OpenExternalURLEffect of int * string
  | RefreshRuntimeLogEffect of int * string * bool * bool
  | CopyRuntimeLogEffect of int * runtime_log_record list
  | SignInEffect of int
  | SignOutEffect of int

type logseq_model =
  { selected_graph : string option
  ; selected_graph_id : string option
  ; graphs : graph list
  ; local_graph_ids : string list
  ; recent_graph_ids : string list
  ; is_graph_encrypted : bool
  ; is_graph_unlocked : bool
  ; unlock_previous_graph_id : string option
  ; graph_loading : bool
  ; graph_password_open : bool
  ; graph_password : string
  ; authentication_state : string
  ; authentication_error : string option
  ; sync_state : sync_state
  ; applied_server_t : int option
  ; has_pending_semantic_operations : bool
  ; has_pending_sync_request : bool
  ; node_icons : string Lui_protocol.String_map.t
  ; pending_sync_error : string option
  ; sync_details_open : bool
  ; destination : primary_destination
  ; sidebar_open : bool
  ; viewport_width : int
  ; graph_menu_open : bool
  ; favorites : sidebar_page list
  ; recent_pages : sidebar_page list
  ; selected_page : sidebar_page option
  ; selected_page_is_tag : bool
  ; selected_page_is_property : bool
  ; selected_page_ready : bool
  ; result_views_json : string
  ; properties_json : string
  ; related_rows : outline_row list
  ; linked_reference_rows : outline_row list
  ; task_statuses : task_status list
  ; task_priorities : task_status list
  ; selected_task_status : task_status option
  ; flashcards : flashcard list
  ; flashcard_cloze_revealed : bool
  ; flashcard_answer_revealed : bool
  ; create_graph_open : bool
  ; new_graph_name : string
  ; new_graph_password : string
  ; new_graph_password_confirmation : string
  ; new_graph_password_required : bool
  ; new_graph_encrypted : bool
  ; pending_graph_deletion : graph option
  ; pending_page_deletion : sidebar_page option
  ; pending_sign_out : bool
  ; connection_menu_open : bool
  ; settings_open : bool
  ; settings_tabs_open : bool
  ; runtime_log_open : bool
  ; appearance : string
  ; settings_appearance_menu_open : bool
  ; language : string
  ; language_choices : settings_language_choice list
  ; settings_language_menu_open : bool
  ; community_links : settings_community_link list
  ; spell_check : bool
  ; auto_correction : bool
  ; sidebar_tabs : string list
  ; base_url : string
  ; base_url_draft : string
  ; version : string
  ; revision : string
  ; runtime_log_source : string
  ; runtime_log_errors_only : bool
  ; runtime_log_newest_first : bool
  ; runtime_log_records : runtime_log_record list
  ; search_open : bool
  ; search_query : string
  ; search_result_pages : search_hit list list
  ; search_result_count : int
  ; search_loading : bool
  ; search_loading_more : bool
  ; search_has_more : bool
  ; node_routes : node_projection list
  ; navigation_root_rows : outline_row list
  ; journal_outliner_rows : outline_row list
  ; outliner_rows : outline_row list
  ; outliner_selected_block_ids : string list
  ; outliner_editing : outliner_editing option
  ; outliner_selection_revision : int
  ; outliner_autocomplete : outliner_autocomplete option
  ; outliner_autocomplete_candidates : outliner_autocomplete_candidate list
  ; outliner_section_markers : journal_section_marker list
  ; has_older_journals : bool
  ; composer_expanded : bool
  ; composer_draft : string
  ; composer_assets : composer_asset list
  ; composer_autofocus : bool
  ; capture_confirmation : int option
  ; pending_effects : logseq_effect list
  ; in_flight_effects : logseq_effect list
  ; next_effect_id : int
  ; result_view_feedback : (string * int * string option) list
  ; effect_error : string option
  ; last_core_response : string option
  ; attachment_picker_open : bool
  ; task_status_picker_open : bool
  ; app_navigation_previews : node_projection list
  ; app_navigation_path : navigation_route list
  ; search_navigation_path : navigation_route list
  ; asset_preview : asset_preview option
  }

type logseq_action =
  | SubmitResultView of string * string
  | SubmitNodeProperty of string * string
  | SelectGraph of string
  | BeginSync
  | SyncSucceeded
  | SyncFailed of string
  | OpenSearch
  | ChangeSearchQuery of string
  | LoadMoreSearchResults
  | EnsureOutlinerRows of string list
  | ApplySearchResults of string * search_hit list
  | ApplyCoreSnapshot of core_projection
  | BeginOutlinerEdit of string
  | ChangeOutlinerText of string * string * int
  | ReturnOutlinerEditor of string * string * int
  | BackspaceOutlinerEditor of string * string * int
  | MoveOutlinerCaret of string * int
  | ToggleOutlinerCollapsed of string
  | LongPressOutlinerBlock of string
  | BeginOutlinerDrag of string
  | DropOutlinerBlocks of string * string
  | ConfirmOutlinerDelete
  | PerformOutlinerToolbarAction of string
  | ChooseOutlinerAutocomplete of string
  | OpenOutlinerAsset of string
  | DismissAssetPreview
  | DismissCaptureConfirmation of int
  | CloseSearch
  | ExpandComposer
  | FocusComposer
  | ApplyComposerDraft of string
  | SaveUISession
  | RestoreUISession of ui_session
  | ChangeComposerDraft of string
  | DismissComposer
  | SendComposer
  | StageComposerAsset of composer_asset
  | RemoveComposerAsset of string
  | DequeueEffect of int
  | ResolveEffect of int * bool * string
  | ResolveAssetPreview of string * string
  | OpenAttachmentPicker
  | CloseAttachmentPicker
  | ChooseAttachment of string
  | OpenTaskStatusPicker
  | CloseTaskStatusPicker
  | ChooseTaskStatus of string
  | ClearTaskStatus
  | RequestAppNode of string
  | ResolveAppNode of string * bool
  | BackAppNavigation of int
  | RequestSearchResult of string
  | RequestSearchNode of string
  | ResolveSearchNode of string * bool
  | BackSearchNavigation of int
  | AddRootBlock of string
  | LoadOlderJournals
  | ApplyViewportWidth of int
  | OpenSidebar
  | CloseSidebar
  | OpenGraphMenu
  | DismissGraphMenu
  | SelectSidebarGraph of string
  | SelectSidebarPage of string
  | OpenQuickAction of string
  | ShowJournals
  | ShowFlashcards
  | ShowGraphs
  | ApplyLocalGraphIds of string list
  | ApplyGraphLoading of bool
  | RefreshGraphs
  | RequestOpenGraph of string
  | ChangeGraphPassword of string
  | SubmitGraphPassword
  | CancelGraphUnlock
  | OpenCreateGraph
  | DismissCreateGraph
  | ChangeNewGraphName of string
  | ToggleNewGraphEncrypted of bool
  | ChangeNewGraphPassword of string
  | ChangeNewGraphPasswordConfirmation of string
  | SubmitCreateGraph
  | RequestDeleteGraph of string
  | CancelDeleteGraph
  | ConfirmDeleteGraph
  | ApplyAuthentication of string * string option
  | SignIn
  | ApplySettingsSnapshot of settings_projection
  | OpenConnectionMenu
  | CloseConnectionMenu
  | ToggleActivePageFavorite
  | ShareActivePage
  | RequestDeleteActivePage
  | CancelDeleteActivePage
  | ConfirmDeleteActivePage
  | OpenSyncDetails
  | CloseSyncDetails
  | SyncNow
  | SetOutlinerTaskStatus of string * string
  | SetOutlinerTaskPriority of string * string
  | OpenJournalCalendar
  | OpenSettings
  | DismissSettings
  | OpenSettingsTabs
  | BackSettings
  | OpenSettingsAppearanceMenu
  | CloseSettingsAppearanceMenu
  | ChangeAppearance of string
  | OpenSettingsLanguageMenu
  | CloseSettingsLanguageMenu
  | ChooseSettingsLanguage of string
  | ToggleSpellCheck of bool
  | ToggleAutoCorrection of bool
  | ToggleSidebarTab of string
  | MoveSidebarTab of string * int
  | ChangeBaseURL of string
  | ApplySettings
  | ExportGraphDatabase
  | OpenExternalURL of string
  | OpenRuntimeLog
  | DismissRuntimeLog
  | ToggleRuntimeLogErrors
  | ToggleRuntimeLogOrder
  | ToggleRuntimeLogSource
  | ApplyRuntimeLog of runtime_log_record list
  | RefreshRuntimeLog
  | CopyRuntimeLog
  | RequestSignOut
  | CancelSignOut
  | SignOut
  | RevealFlashcardCloze
  | RevealFlashcardAnswer
  | ReviewFlashcard of string

val sub_list : int -> int -> 'a list -> 'a list
val last_opt : 'a list -> 'a option
val task_status : string -> string -> string -> string -> task_status
val built_in_task_statuses : unit -> task_status list
val settings_language_choices : unit -> settings_language_choice list
val settings_community_links : unit -> settings_community_link list
val settings_language_by_id :
  settings_language_choice list -> string -> settings_language_choice option
val settings_language_choice_selected_ :
  logseq_model -> settings_language_choice -> bool
val initial : unit -> logseq_model
val journal_section_key : outline_row -> string option
val refresh_journal_window :
  outline_row list -> outline_row list -> outline_row list
val journal_section_title : outline_row -> string
val journal_section_markers : outline_row list -> journal_section_marker list
val finish_journal_section :
  journal_section_marker list ->
  outline_row option ->
  int ->
  int ->
  journal_section_marker list
val node_route_by_uuid : node_projection list -> string -> node_projection option
val journal_preview_route : logseq_model -> string -> node_projection option
val outliner_preview_end_index : outline_row list -> int -> int -> int
val outliner_preview_route : logseq_model -> string -> node_projection option
val publish_navigation_preview : logseq_model -> string -> logseq_model
val app_node_routes_from :
  logseq_model -> navigation_route list -> int -> node_projection list
val app_node_routes : logseq_model -> node_projection list
val sidebar_page_in : sidebar_page list -> string -> sidebar_page option
val sidebar_page_by_uuid : logseq_model -> string -> sidebar_page option
val journal_rows_for_page : logseq_model -> string -> outline_row list
val preview_sidebar_page : logseq_model -> string -> logseq_model
val request_route :
  navigation_route list -> navigation_route -> navigation_route list
val resolve_route :
  navigation_route list -> navigation_route -> bool -> navigation_route list
val pop_route : navigation_route list -> navigation_route list
val remove_node_projection :
  node_projection list -> string -> node_projection list
val back_app_navigation : logseq_model -> int -> logseq_model
val back_search_navigation : logseq_model -> int -> logseq_model
val return_to_app_root : logseq_model -> logseq_model
val navigation_route_uuid : navigation_route -> string
val effect_id : logseq_effect -> int
val effect_with_id : logseq_effect list -> int -> logseq_effect option
val contains_sign_in_effect_ : logseq_effect list -> bool
val contains_load_older_journals_effect_ : logseq_effect list -> bool
val contains_journal_refresh_effect_ : logseq_effect list -> bool
val load_older_journals_active_ : logseq_model -> bool
val journal_refresh_active_ : logseq_model -> bool
val graph_effect_key : logseq_effect -> string
val contains_graph_effect_ : logseq_effect list -> string -> bool
val graph_effect_active_ : logseq_model -> string -> bool
val graph_refresh_active_ : logseq_model -> bool
val graph_create_active_ : logseq_model -> bool
val graph_unlock_active_ : logseq_model -> bool
val graph_delete_active_ : logseq_model -> string -> bool
val sign_in_active_ : logseq_model -> bool
val change_outliner_text_effect_for_ : logseq_effect -> string -> bool
val contains_change_outliner_text_effect_ : logseq_effect list -> string -> bool
val change_outliner_text_active_ : logseq_model -> string -> bool
val snapshot_outliner_editing :
  logseq_model -> core_projection -> outliner_editing option
val first_flashcard_id : flashcard list -> string option
val graph_by_id : graph list -> string -> graph option
val task_status_by_id : task_status list -> string -> task_status option
val task_status_identity : task_status -> string
val contains_task_status_identity_ : task_status list -> string -> bool
val available_task_statuses : task_status list -> task_status list
val string_vector_contains_ : string list -> string -> bool
val graph_local_ : logseq_model -> string -> bool
val remove_string : string list -> string -> string list
val required_sidebar_tab_ : string -> bool
val valid_sidebar_tab_ : string -> bool
val normalize_sidebar_tabs : string list -> string list
val toggle_sidebar_tab : string list -> string -> string list
val move_sidebar_tab : string list -> string -> int -> string list
val bounded_url_delimiter : int -> int -> int
val string_index_of_opt : string -> string -> int
val valid_base_url_ : string -> bool
val valid_attachment_kind_ : string -> bool
val indexed_outliner_autocomplete_candidates :
  outliner_autocomplete_candidate list -> outliner_autocomplete_candidate list
val valid_authentication_state_ : string -> bool
val current_settings : logseq_model -> settings_projection
val active_page : logseq_model -> sidebar_page option
val page_is_favorite_ : logseq_model -> string -> bool
val page_share_text : sidebar_page -> outline_row list -> string
val page_share_asset_paths : outline_row list -> string list
val rollback_navigation_effect : logseq_model -> logseq_effect -> logseq_model
val resolve_successful_effect : logseq_model -> logseq_effect -> string -> logseq_model
val resolve_failed_effect : logseq_model -> logseq_effect -> string -> logseq_model
val enqueue_close_search_effects :
  logseq_model -> navigation_route list -> logseq_model
val enqueue_effect : logseq_model -> logseq_effect -> logseq_model
val enqueue_open_graph : logseq_model -> string -> logseq_model
val persist_settings_change : logseq_model -> logseq_model -> logseq_model
val update_editing : logseq_model -> string -> string -> int -> logseq_model
val cancel_outliner_editing : logseq_model -> logseq_model
val row_index : outline_row list -> string -> int option
val contains_row_ : outline_row list -> string -> bool
val splice_start : outline_row list -> outline_row_splice -> int option
val apply_row_splice :
  outline_row list -> outline_row_splice -> outline_row list
val apply_row_splices :
  outline_row list -> outline_row_splice list -> outline_row list
val merge_row_replacements :
  outline_row list -> outline_row list -> outline_row list
val remove_effect : logseq_effect list -> int -> logseq_effect list
val remove_search_effects : logseq_effect list -> logseq_effect list
val remove_composer_draft_effects : logseq_effect list -> logseq_effect list
val update : logseq_model -> logseq_action -> logseq_model
val editing_sync_state : logseq_model -> sync_state
val ui_session : logseq_model -> ui_session
val restore_session_routes :
  logseq_model -> navigation_route list -> bool -> logseq_model
val restore_ui_session : logseq_model -> ui_session -> logseq_model

val graph_creation_password_invalid_ : logseq_model -> bool

val wide_content_breakpoint : int
