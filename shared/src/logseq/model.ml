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

(* The asset currently shown by the file-preview node (QuickLook on Apple).
   The node stays mounted while this is [Some]; the backend's Dismiss event
   clears it through [DismissAssetPreview]. *)
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
  ; flashcards : flashcard list
  ; sync_connected : bool
  ; applied_server_t : int option
  ; has_pending_semantic_operations : bool
  ; has_pending_sync_request : bool
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
  ; related_rows : outline_row list
  ; linked_reference_rows : outline_row list
  ; task_statuses : task_status list
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

let sub_list start stop xs =
  xs
  |> List.mapi (fun i x -> (i, x))
  |> List.filter_map (fun (i, x) ->
         if i >= start && i < stop then Some x else None)

let last_opt xs =
  match List.rev xs with
  | x :: _ -> Some x
  | [] -> None

let task_status uuid ident title icon_id =
  {
    uuid;
    ident = Some ident;
    title;
    icon_type = Some "tabler-icon";
    icon_id = Some icon_id;
    icon_color = None;
  }

let built_in_task_statuses () =
  [
    task_status "backlog" "logseq.property/status.backlog" "Backlog" "Backlog";
    task_status "todo" "logseq.property/status.todo" "Todo" "Todo";
    task_status "doing" "logseq.property/status.doing" "Doing" "InProgress50";
    task_status "in-review" "logseq.property/status.in-review" "In Review"
      "InReview";
    task_status "done" "logseq.property/status.done" "Done" "Done";
    task_status "canceled" "logseq.property/status.canceled" "Canceled"
      "Cancelled";
  ]

let settings_language_choices () =
  [
    { id = "system"; title = "System" };
    { id = "en"; title = "English" };
    { id = "fr"; title = "Français" };
    { id = "de"; title = "Deutsch" };
    { id = "nl"; title = "Dutch (Nederlands)" };
    { id = "zh-CN"; title = "简体中文" };
    { id = "zh-Hant"; title = "繁體中文" };
    { id = "af"; title = "Afrikaans" };
    { id = "ca"; title = "Català" };
    { id = "es"; title = "Español" };
    { id = "vi"; title = "Tiếng Việt" };
    { id = "nb-NO"; title = "Norsk (bokmål)" };
    { id = "pl"; title = "Polski" };
    { id = "pt-BR"; title = "Português (Brasileiro)" };
    { id = "pt-PT"; title = "Português (Europeu)" };
    { id = "ru"; title = "Русский" };
    { id = "ja"; title = "日本語" };
    { id = "it"; title = "Italiano" };
    { id = "tr"; title = "Türkçe" };
    { id = "uk"; title = "Українська" };
    { id = "ko"; title = "한국어" };
    { id = "sk"; title = "Slovenčina" };
    { id = "fa"; title = "فارسی" };
    { id = "id"; title = "Bahasa Indonesia" };
    { id = "cs"; title = "Čeština" };
    { id = "ar"; title = "العربية" };
  ]

let settings_community_links () =
  [
    {
      id = "report-bug";
      title = "Report bug";
      url = "https://github.com/logseq/db-test/issues";
    };
    {
      id = "discord";
      title = "Discord community";
      url = "https://discord.com/invite/KpN4eHY";
    };
    { id = "forum"; title = "Forum"; url = "https://discuss.logseq.com" };
    { id = "github"; title = "GitHub"; url = "https://github.com/logseq/logseq" };
  ]

let settings_language_by_id choices target =
  List.find_opt
    (fun (choice : settings_language_choice) -> choice.id = target)
    choices

let settings_language_choice_selected_ (current : logseq_model)
    (choice : settings_language_choice) =
  current.language = choice.id

let initial () =
  {
    selected_graph = None;
    selected_graph_id = None;
    graphs = [];
    local_graph_ids = [];
    recent_graph_ids = [];
    is_graph_encrypted = false;
    is_graph_unlocked = false;
    unlock_previous_graph_id = None;
    graph_loading = false;
    graph_password_open = false;
    graph_password = "";
    authentication_state = "restoring";
    authentication_error = None;
    sync_state = OfflineState;
    applied_server_t = None;
    has_pending_semantic_operations = false;
    has_pending_sync_request = false;
    sync_details_open = false;
    destination = JournalsDestination;
    sidebar_open = false;
    viewport_width = 0;
    graph_menu_open = false;
    favorites = [];
    recent_pages = [];
    selected_page = None;
    selected_page_is_tag = false;
    selected_page_is_property = false;
    selected_page_ready = true;
    related_rows = [];
    linked_reference_rows = [];
    task_statuses = built_in_task_statuses ();
    selected_task_status = None;
    flashcards = [];
    flashcard_cloze_revealed = false;
    flashcard_answer_revealed = false;
    create_graph_open = false;
    new_graph_name = "";
    new_graph_password = "";
    new_graph_password_confirmation = "";
    new_graph_password_required = false;
    new_graph_encrypted = true;
    pending_graph_deletion = None;
    pending_page_deletion = None;
    pending_sign_out = false;
    connection_menu_open = false;
    settings_open = false;
    settings_tabs_open = false;
    runtime_log_open = false;
    appearance = "system";
    settings_appearance_menu_open = false;
    language = "system";
    language_choices = settings_language_choices ();
    settings_language_menu_open = false;
    community_links = settings_community_links ();
    spell_check = true;
    auto_correction = true;
    sidebar_tabs = [ "journals"; "flashcards"; "graphs" ];
    base_url = "https://api.logseq.io";
    base_url_draft = "https://api.logseq.io";
    version = "Development";
    revision = "Development";
    runtime_log_source = "ui";
    runtime_log_errors_only = false;
    runtime_log_newest_first = false;
    runtime_log_records = [];
    search_open = false;
    search_query = "";
    search_result_pages = [];
    search_result_count = 0;
    search_loading = false;
    search_loading_more = false;
    search_has_more = false;
    node_routes = [];
    navigation_root_rows = [];
    journal_outliner_rows = [];
    outliner_rows = [];
    outliner_selected_block_ids = [];
    outliner_editing = None;
    outliner_selection_revision = 0;
    outliner_autocomplete = None;
    outliner_autocomplete_candidates = [];
    outliner_section_markers = [];
    has_older_journals = false;
    composer_expanded = false;
    composer_draft = "";
    composer_assets = [];
    composer_autofocus = false;
    capture_confirmation = None;
    pending_effects = [];
    in_flight_effects = [];
    next_effect_id = 1;
    effect_error = None;
    last_core_response = None;
    attachment_picker_open = false;
    task_status_picker_open = false;
    asset_preview = None;
    app_navigation_previews = [];
    app_navigation_path = [];
    search_navigation_path = [];
  }

let request_route path route =
  match last_opt path with
  | Some last when last = route -> path
  | _ -> path @ [ route ]

let resolve_route path route resolved =
  if resolved then path
  else begin
    let rec loop index =
      if index < 0 then path
      else if List.nth path index = route then
        sub_list 0 index path @ sub_list (index + 1) (List.length path) path
      else loop (index - 1)
    in
    loop (List.length path - 1)
  end

let pop_route path =
  match path with
  | [] -> []
  | _ -> sub_list 0 (List.length path - 1) path

let remove_node_projection routes uuid =
  List.filter (fun (route : node_projection) -> route.node_uuid <> uuid)
    routes

let navigation_route_uuid route =
  match route with
  | NodeRoute uuid -> uuid

let effect_id eff =
  match eff with
  | SendCaptureEffect (id, _) -> id
  | SendAssetEffect (id, _) -> id
  | SendTaskEffect (id, _, _) -> id
  | PersistComposerDraftEffect (id, _) -> id
  | PersistUISessionEffect (id, _) -> id
  | PresentJournalCalendarEffect id -> id
  | PresentAttachmentEffect (id, _) -> id
  | PresentAssetEffect (id, _, _, _) -> id
  | PresentPageShareEffect (id, _, _) -> id
  | SetPageFavoriteEffect (id, _, _) -> id
  | DeletePageEffect (id, _) -> id
  | SyncNowEffect id -> id
  | SyncPendingEffect id -> id
  | SetOutlinerTaskStatusEffect (id, _, _) -> id
  | SearchNodesEffect (id, _) | LoadSearchPageEffect (id, _, _) -> id
  | LoadPageReferencesEffect (id, _) -> id
  | HydrateOutlinerRowsEffect (id, _) -> id
  | TapOutlinerBlockEffect (id, _) -> id
  | ChangeOutlinerTextEffect (id, _, _, _) -> id
  | ReturnOutlinerEditorEffect (id, _, _, _) -> id
  | BackspaceOutlinerEditorEffect (id, _, _, _) -> id
  | MoveOutlinerCaretEffect (id, _, _) -> id
  | ToggleOutlinerCollapsedEffect (id, _) -> id
  | LongPressOutlinerBlockEffect (id, _) -> id
  | DropOutlinerBlocksEffect (id, _, _) -> id
  | OutlinerToolbarEffect (id, _) -> id
  | ChooseOutlinerAutocompleteEffect (id, _) -> id
  | ConfirmOutlinerDeleteEffect id -> id
  | SaveOutlinerEditingEffect (id, _) -> id
  | CancelOutlinerEditingEffect id -> id
  | OpenAppNodeEffect (id, _) -> id
  | OpenSearchResultEffect (id, _)
  | OpenSearchNodeEffect (id, _) -> id
  | CloseAppNodeEffect (id, _) -> id
  | CloseSearchNodeEffect (id, _) -> id
  | AddRootBlockEffect (id, _) -> id
  | SelectSidebarPageEffect (id, _) -> id
  | ClearSelectedPageEffect id -> id
  | LoadOlderJournalsEffect id -> id
  | LoadFlashcardsEffect id -> id
  | ReviewFlashcardEffect (id, _, _) -> id
  | RefreshGraphsEffect id -> id
  | OpenGraphEffect (id, _) -> id
  | UnlockGraphEffect (id, _) -> id
  | CreateGraphEffect (id, _, _, _) -> id
  | DeleteLocalGraphEffect (id, _) -> id
  | SaveSettingsEffect (id, _) -> id
  | ExportGraphDatabaseEffect id -> id
  | OpenExternalURLEffect (id, _) -> id
  | RefreshRuntimeLogEffect (id, _, _, _) -> id
  | CopyRuntimeLogEffect (id, _) -> id
  | SignInEffect id -> id
  | SignOutEffect id -> id

let effect_with_id effects target =
  List.find_opt (fun eff -> effect_id eff = target) effects

let graph_creation_password_invalid_ (current : logseq_model) =
  current.new_graph_encrypted && current.new_graph_password_required
  && (String_kit.is_blank current.new_graph_password
      || current.new_graph_password <> current.new_graph_password_confirmation)

let contains_sign_in_effect_ effects =
  List.exists
    (fun eff ->
      match eff with
      | SignInEffect _ -> true
      | _ -> false)
    effects

let contains_load_older_journals_effect_ effects =
  List.exists
    (fun eff ->
      match eff with
      | LoadOlderJournalsEffect _ -> true
      | _ -> false)
    effects

let load_older_journals_active_ (current : logseq_model) =
  contains_load_older_journals_effect_ current.pending_effects
  || contains_load_older_journals_effect_ current.in_flight_effects

let contains_journal_refresh_effect_ effects =
  List.exists
    (fun eff ->
      match eff with
      | LoadOlderJournalsEffect _ -> true
      | SendCaptureEffect _ -> true
      | SendTaskEffect _ -> true
      | _ -> false)
    effects

let journal_refresh_active_ (current : logseq_model) =
  contains_journal_refresh_effect_ current.pending_effects
  || contains_journal_refresh_effect_ current.in_flight_effects

let graph_effect_key eff =
  match eff with
  | RefreshGraphsEffect _ -> "refresh"
  | CreateGraphEffect _ -> "create"
  | UnlockGraphEffect _ -> "unlock"
  | DeleteLocalGraphEffect (_, graph_id) -> "delete:" ^ graph_id
  | _ -> ""

let contains_graph_effect_ effects key =
  List.exists (fun eff -> graph_effect_key eff = key) effects

let graph_effect_active_ (current : logseq_model) key =
  contains_graph_effect_ current.pending_effects key
  || contains_graph_effect_ current.in_flight_effects key

let graph_refresh_active_ current = graph_effect_active_ current "refresh"
let graph_create_active_ current = graph_effect_active_ current "create"
let graph_unlock_active_ current = graph_effect_active_ current "unlock"

let graph_delete_active_ current graph_id =
  graph_effect_active_ current ("delete:" ^ graph_id)

let sign_in_active_ (current : logseq_model) =
  contains_sign_in_effect_ current.pending_effects
  || contains_sign_in_effect_ current.in_flight_effects

let change_outliner_text_effect_for_ eff uuid =
  match eff with
  | ChangeOutlinerTextEffect (_, effect_uuid, _, _) -> effect_uuid = uuid
  | _ -> false

let contains_change_outliner_text_effect_ effects uuid =
  List.exists (fun eff -> change_outliner_text_effect_for_ eff uuid)
    effects

let remove_trailing_outliner_inputs effects uuid =
  let rec drop = function
    | ChangeOutlinerTextEffect (_, id, _, _) :: rest
    | MoveOutlinerCaretEffect (_, id, _) :: rest when id = uuid -> drop rest
    | rest -> rest
  in
  List.rev (drop (List.rev effects))

let change_outliner_text_active_ (current : logseq_model) uuid =
  contains_change_outliner_text_effect_ current.pending_effects uuid
  || contains_change_outliner_text_effect_ current.in_flight_effects uuid

let snapshot_outliner_editing (current : logseq_model) projection =
  match current.outliner_editing with
  | Some editing ->
    if change_outliner_text_active_ current editing.editing_uuid then
      Some editing
    else projection.projection_outliner_editing
  | None -> projection.projection_outliner_editing

let first_flashcard_id flashcards =
  match flashcards with
  | card :: _ -> Some card.flashcard_uuid
  | [] -> None

let journal_section_key (row : outline_row) =
  match row.journal_day with
  | Some day -> Some (string_of_int day)
  | None ->
    (match row.journal_title with
     | Some title -> if String_kit.is_blank title then None else Some title
     | None -> None)

let journal_section_title (row : outline_row) =
  match row.journal_title with
  | Some title ->
    if String_kit.is_blank title then
      match row.journal_day with
      | Some day -> string_of_int day
      | None -> ""
    else title
  | None ->
    (match row.journal_day with
     | Some day -> string_of_int day
     | None -> "")

let refresh_journal_window current_rows projected_rows =
  let oldest_day =
    List.fold_left
      (fun oldest (row : outline_row) ->
        match (oldest, row.journal_day) with
        | Some previous, Some day -> Some (min day previous)
        | None, Some day -> Some day
        | _, None -> oldest)
      None current_rows
  in
  List.filter
    (fun (row : outline_row) ->
      match oldest_day with
      | None -> true
      | Some oldest ->
        (match row.journal_day with
         | None -> true
         | Some day -> day >= oldest))
    projected_rows

let finish_journal_section result start start_index end_index =
  match start with
  | Some (row : outline_row) ->
        {
          block_id = row.row_uuid;
          page_id = row.page_id;
          section_title = journal_section_title row;
          has_divider = result <> [];
          start_index;
          end_index;
        } :: result
  | None -> result

let journal_section_markers rows =
  let rec loop index section_key section_start section_start_index result = function
    | [] -> List.rev (finish_journal_section result section_start section_start_index index)
    | row :: rest ->
      let row_key = journal_section_key row in
      let starts_section =
        match row_key with
        | Some _ -> row_key <> section_key
        | None -> false
      in
      let next_result =
        if starts_section then
          finish_journal_section result section_start section_start_index
            index
        else result
      in
      loop (index + 1)
        (if starts_section then row_key else section_key)
        (if starts_section then Some row else section_start)
        (if starts_section then index else section_start_index)
        next_result rest
  in
  loop 0 None None 0 [] rows

let node_route_by_uuid routes uuid =
  List.find_opt (fun (route : node_projection) -> route.node_uuid = uuid)
    routes

let journal_preview_route (current : logseq_model) uuid =
  let rows = current.journal_outliner_rows in
  let markers = journal_section_markers rows in
  match
    List.find_opt
      (fun (section : journal_section_marker) -> section.page_id = uuid)
      markers
  with
  | Some section ->
    Some
      {
        node_uuid = uuid;
        node_page_uuid = uuid;
        node_title = section.section_title;
        node_breadcrumbs = [];
        node_scroll_target = None;
        node_is_tag = false;
        node_is_property = false;
        node_outliner_rows =
          sub_list section.start_index section.end_index rows;
        node_related_rows = [];
        node_linked_reference_rows = [];
        node_outliner_editing = None;
        node_outliner_autocomplete = None;
        node_outliner_autocomplete_candidates = [];
        node_outliner_selected_block_ids = [];
      }
  | None -> None

let outliner_preview_end_index rows start depth =
  let rec skip remaining rows =
    if remaining = 0 then rows
    else match rows with [] -> [] | _ :: rest -> skip (remaining - 1) rest in
  let rec loop index = function
    | [] -> index
    | row :: rest -> if row.depth <= depth then index else loop (index + 1) rest in
  loop (start + 1) (skip (start + 1) rows)

let row_index rows uuid =
  let rec loop index rows =
    match rows with
    | [] -> None
    | (row : outline_row) :: rest ->
      if row.row_uuid = uuid then Some index else loop (index + 1) rest
  in
  loop 0 rows

let outliner_preview_route (current : logseq_model) uuid =
  let rows = current.outliner_rows in
  match row_index rows uuid with
  | Some index ->
    let row = List.nth rows index in
    let end_index = outliner_preview_end_index rows index row.depth in
    Some
      {
        node_uuid = uuid;
        node_page_uuid = row.page_id;
        node_title = row.row_title;
        node_breadcrumbs = row.row_breadcrumbs;
        node_scroll_target = None;
        node_is_tag = false;
        node_is_property = false;
        node_outliner_rows = sub_list index end_index rows;
        node_related_rows = [];
        node_linked_reference_rows = [];
        node_outliner_editing = None;
        node_outliner_autocomplete = None;
        node_outliner_autocomplete_candidates = [];
        node_outliner_selected_block_ids = [];
      }
  | None -> None

let publish_navigation_preview current uuid =
  match node_route_by_uuid current.node_routes uuid with
  | Some _ -> current
  | None ->
    (match node_route_by_uuid current.app_navigation_previews uuid with
     | Some _ -> current
     | None ->
       (match journal_preview_route current uuid with
        | Some preview ->
          {
            current with
            app_navigation_previews =
              current.app_navigation_previews @ [ preview ];
          }
        | None ->
          (match outliner_preview_route current uuid with
           | Some preview ->
             {
               current with
               app_navigation_previews =
                 current.app_navigation_previews @ [ preview ];
             }
           | None -> current)))

let rec app_node_routes_from (current : logseq_model) path index =
  if index = List.length path then []
  else begin
    let uuid = navigation_route_uuid (List.nth path index) in
    let route =
      match node_route_by_uuid current.node_routes uuid with
      | Some resolved -> Some resolved
      | None -> node_route_by_uuid current.app_navigation_previews uuid
    in
    match route with
    | Some resolved -> resolved :: app_node_routes_from current path (index + 1)
    | None -> []
  end

let app_node_routes current =
  app_node_routes_from current current.app_navigation_path 0

let sidebar_page_in pages uuid =
  List.find_opt (fun (page : sidebar_page) -> page.uuid = uuid) pages

let sidebar_page_by_uuid current uuid =
  match sidebar_page_in current.favorites uuid with
  | Some page -> Some page
  | None -> sidebar_page_in current.recent_pages uuid

let journal_rows_for_page current uuid =
  let rows = current.journal_outliner_rows in
  let markers = journal_section_markers rows in
  match
    List.find_opt
      (fun (marker : journal_section_marker) -> marker.page_id = uuid)
      markers
  with
  | Some marker -> sub_list marker.start_index marker.end_index rows
  | None -> []

let preview_sidebar_page (current : logseq_model) uuid =
  let already_loaded =
    current.selected_page_ready && current.node_routes = []
    && match current.selected_page with
       | Some page -> page.uuid = uuid
       | None -> false
  in
  if already_loaded then current
  else match sidebar_page_by_uuid current uuid with
  | Some page ->
    let rows = journal_rows_for_page current uuid in
    {
      current with
      selected_page = Some page;
      selected_page_ready = rows <> [];
      selected_page_is_tag = false;
      selected_page_is_property = false;
      related_rows = [];
      linked_reference_rows = [];
      outliner_rows = rows;
      outliner_section_markers = journal_section_markers rows;
    }
  | None -> current

let graph_by_id graphs target =
  List.find_opt (fun (graph : graph) -> graph.id = target) graphs

let task_status_by_id statuses target =
  List.find_opt (fun (status : task_status) -> status.uuid = target) statuses

let task_status_identity status =
  match status.ident with
  | Some ident -> ident
  | None -> status.uuid

let contains_task_status_identity_ statuses target =
  List.exists
    (fun status -> task_status_identity status = target)
    statuses

let available_task_statuses catalog =
  List.fold_left
    (fun choices status ->
      if contains_task_status_identity_ choices (task_status_identity status)
      then choices
      else choices @ [ status ])
    catalog (built_in_task_statuses ())

let string_vector_contains_ values target = List.mem target values

let graph_local_ (current : logseq_model) graph_id =
  string_vector_contains_ current.local_graph_ids graph_id

let remove_string values target =
  List.filter (fun value -> value <> target) values

let required_sidebar_tab_ tab = tab = "journals" || tab = "graphs"

let valid_sidebar_tab_ tab =
  tab = "journals" || tab = "flashcards" || tab = "graphs"

let normalize_sidebar_tabs tabs =
  match tabs with
  | [] -> [ "journals"; "flashcards"; "graphs" ]
  | _ ->
    let normalized =
      List.fold_left
        (fun result tab ->
          if
            valid_sidebar_tab_ tab
            && tab <> "journals"
            && not (string_vector_contains_ result tab)
          then result @ [ tab ]
          else result)
        [ "journals" ] tabs
    in
    if string_vector_contains_ normalized "graphs" then normalized
    else normalized @ [ "graphs" ]

let toggle_sidebar_tab tabs tab =
  if tab <> "flashcards" then tabs
  else if string_vector_contains_ tabs tab then remove_string tabs tab
  else tabs @ [ tab ]

let move_sidebar_tab tabs tab offset =
  if tab = "journals" then tabs
  else begin
    let without = remove_string tabs tab in
    let rec loop index =
      if index = List.length tabs then tabs
      else if List.nth tabs index = tab then
        let target =
          min (max (index + offset) 0) (List.length without)
        in
        sub_list 0 target without @ (tab :: sub_list target (List.length without) without)
      else loop (index + 1)
    in
    loop 0
  end

let bounded_url_delimiter index fallback = if index < 0 then fallback else index

let string_index_of_opt s sub =
  let n = String.length s in
  let m = String.length sub in
  let rec search i =
    if i + m > n then -1
    else if String.sub s i m = sub then i
    else search (i + 1)
  in
  search 0

let valid_base_url_ value =
  let normalized = String.trim value in
  let prefix_length =
    if String.starts_with ~prefix:"https://" normalized then 8
    else if String.starts_with ~prefix:"http://" normalized then 7
    else 0
  in
  if prefix_length = 0 then false
  else begin
    let remainder =
      String.sub normalized prefix_length
        (String.length normalized - prefix_length)
    in
    let length = String.length remainder in
    let host_end =
      min
        (min
           (bounded_url_delimiter (string_index_of_opt remainder "/") length)
           (bounded_url_delimiter (string_index_of_opt remainder "?") length))
        (bounded_url_delimiter (string_index_of_opt remainder "#") length)
    in
    let host = String.sub remainder 0 host_end in
    String.trim host <> ""
    && not (String_kit.includes normalized ~sub:" ")
    && not (String_kit.includes normalized ~sub:"\n")
    && not (String_kit.includes normalized ~sub:"\r")
  end

let valid_attachment_kind_ kind =
  kind = "files" || kind = "camera" || kind = "photos" || kind = "audio"

let indexed_outliner_autocomplete_candidates candidates =
  List.mapi
    (fun index (candidate : outliner_autocomplete_candidate) ->
      { candidate with candidate_index = index })
    candidates

let reference_autocomplete_candidates (current : logseq_model) =
  match current.outliner_autocomplete with
  | Some { autocomplete_kind = (TagAutocomplete | NodeAutocomplete); _ } ->
    current.outliner_autocomplete_candidates
  | _ -> []

let stale_autocomplete_snapshot (current : logseq_model) projection =
  match current.outliner_editing with
  | Some editing when change_outliner_text_active_ current editing.editing_uuid ->
    current.outliner_editing <> projection.projection_outliner_editing
  | _ -> false

let snapshot_autocomplete_candidates (current : logseq_model) projection =
  if stale_autocomplete_snapshot current projection then
    reference_autocomplete_candidates current
  else indexed_outliner_autocomplete_candidates
    projection.projection_outliner_autocomplete_candidates

let snapshot_autocomplete (current : logseq_model) projection =
  if stale_autocomplete_snapshot current projection then current.outliner_autocomplete
  else projection.projection_outliner_autocomplete

let valid_authentication_state_ state =
  state = "restoring" || state = "signedOut" || state = "signingIn"
  || state = "signedIn" || state = "signingOut"

let current_settings (current : logseq_model) =
  {
    appearance = current.appearance;
    language = current.language;
    spell_check = current.spell_check;
    auto_correction = current.auto_correction;
    sidebar_tabs = current.sidebar_tabs;
    base_url = String.trim current.base_url;
    version = current.version;
    revision = current.revision;
  }

let active_page (current : logseq_model) =
  if current.destination <> JournalsDestination then None
  else begin
    let routes = app_node_routes current in
    match routes with
    | [] -> current.selected_page
    | _ ->
      (match last_opt routes with
       | Some route ->
         Some { uuid = route.node_page_uuid; title = route.node_title }
       | None -> None)
  end

let page_is_favorite_ (current : logseq_model) uuid =
  List.exists (fun (page : sidebar_page) -> page.uuid = uuid)
    current.favorites

let page_share_text (page : sidebar_page) rows =
  let lines =
    List.fold_left
      (fun lines (row : outline_row) ->
        let title = String.trim row.row_title in
        if title = "" then lines else lines @ [ "- " ^ title ])
      [ page.title ] rows
  in
  String.concat "\n" lines

let page_share_asset_paths rows =
  List.fold_left
    (fun paths (row : outline_row) ->
      match row.local_path with
      | Some path ->
        if
          row.is_asset && path <> ""
          && not (string_vector_contains_ paths path)
        then paths @ [ path ]
        else paths
      | None -> paths)
    [] rows

let cancels_outliner_autosave = function
  | OutlinerToolbarEffect (_, action) ->
    (* Movement and media actions retain the draft without committing it. *)
    List.mem action [ "hideKeyboard"; "tag"; "pageReference"; "delete" ]
  | ChangeOutlinerTextEffect _ | ReturnOutlinerEditorEffect _
  | BackspaceOutlinerEditorEffect _ | TapOutlinerBlockEffect _
  | ToggleOutlinerCollapsedEffect _ | LongPressOutlinerBlockEffect _
  | DropOutlinerBlocksEffect _
  | ConfirmOutlinerDeleteEffect _
  | ChooseOutlinerAutocompleteEffect _ | CancelOutlinerEditingEffect _
  | SetOutlinerTaskStatusEffect _ | SelectSidebarPageEffect _
  | ClearSelectedPageEffect _ | OpenAppNodeEffect _ | CloseAppNodeEffect _
  | OpenSearchNodeEffect _ | CloseSearchNodeEffect _ | OpenSearchResultEffect _
  | OpenGraphEffect _ | DeleteLocalGraphEffect _ | SignOutEffect _ -> true
  | _ -> false

let cancel_outliner_autosave current =
  { current with pending_effects = List.filter (function
      | SaveOutlinerEditingEffect _ -> false
      | _ -> true) current.pending_effects }

let enqueue_effect (current : logseq_model) eff =
  let current = if cancels_outliner_autosave eff then cancel_outliner_autosave current else current in
  {
    current with
    pending_effects = current.pending_effects @ [ eff ];
    next_effect_id = current.next_effect_id + 1;
    effect_error = None;
  }

let cancel_outliner_editing (current : logseq_model) =
  let current = cancel_outliner_autosave current in
  match current.outliner_editing with
  | Some _ ->
    let updated =
      {
        current with
        outliner_editing = None;
        outliner_autocomplete = None;
        outliner_autocomplete_candidates = [];
      }
    in
    let id = updated.next_effect_id in
    {
      updated with
      pending_effects = updated.pending_effects @ [ CancelOutlinerEditingEffect id ];
      next_effect_id = id + 1;
      effect_error = None;
    }
  | None -> current

let back_app_navigation (current : logseq_model) requested =
  if requested = 0 then
    (* System back below the last pushed route: settle transient state
       instead — leave editing/selection and return pane destinations to
       journals. *)
    if
      current.destination = JournalsDestination
      && current.outliner_selected_block_ids = []
      && current.outliner_editing = None
    then current
    else
      {
        (cancel_outliner_editing current) with
        outliner_selected_block_ids = [];
        destination = JournalsDestination;
      }
  else
    let rec loop remaining updated =
    if remaining = 0 then updated
    else begin
      let path = updated.app_navigation_path in
      let uuid = navigation_route_uuid (List.nth path (List.length path - 1)) in
      let popped =
        {
          (cancel_outliner_editing updated) with
          app_navigation_path = pop_route path;
          app_navigation_previews =
            remove_node_projection updated.app_navigation_previews uuid;
        }
      in
      let id = popped.next_effect_id in
      loop (remaining - 1)
        {
          popped with
          pending_effects =
            popped.pending_effects @ [ CloseAppNodeEffect (id, uuid) ];
          next_effect_id = id + 1;
          effect_error = None;
        }
    end
  in
  loop
    (min (max requested 0) (List.length current.app_navigation_path))
    current

let return_to_app_root current =
  back_app_navigation current (List.length current.app_navigation_path)

let back_search_navigation current requested =
  let rec loop remaining updated =
    if remaining = 0 then updated
    else begin
      let path = updated.search_navigation_path in
      let uuid = navigation_route_uuid (List.nth path (List.length path - 1)) in
      let popped =
        {
          (cancel_outliner_editing updated) with
          search_navigation_path = pop_route path;
        }
      in
      let id = popped.next_effect_id in
      loop (remaining - 1)
        {
          popped with
          pending_effects =
            popped.pending_effects @ [ CloseSearchNodeEffect (id, uuid) ];
          next_effect_id = id + 1;
          effect_error = None;
        }
    end
  in
  loop
    (min (max requested 0) (List.length current.search_navigation_path))
    current

let rollback_navigation_effect (current : logseq_model) eff =
  match eff with
  | OpenAppNodeEffect (_, uuid) ->
    {
      current with
      app_navigation_path =
        resolve_route current.app_navigation_path (NodeRoute uuid) false;
      app_navigation_previews =
        remove_node_projection current.app_navigation_previews uuid;
    }
  | OpenSearchResultEffect (_, uuid)
  | OpenSearchNodeEffect (_, uuid) ->
    {
      current with
      search_navigation_path =
        resolve_route current.search_navigation_path (NodeRoute uuid) false;
    }
  | CloseAppNodeEffect (_, uuid) ->
    {
      current with
      app_navigation_path =
        request_route current.app_navigation_path (NodeRoute uuid);
    }
  | CloseSearchNodeEffect (_, uuid) ->
    {
      current with
      search_navigation_path =
        request_route current.search_navigation_path (NodeRoute uuid);
    }
  | SelectSidebarPageEffect _ -> { current with sidebar_open = true }
  | OpenGraphEffect _ -> { current with graph_loading = false }
  | _ -> current

let resolve_failed_effect (current : logseq_model) eff message =
  match eff with
  | SignInEffect _ ->
    {
      current with
      authentication_state = "signedOut";
      authentication_error = Some message;
    }
  | RefreshGraphsEffect _ ->
    { current with sync_state = FailedState message }
  | CreateGraphEffect _ when String.ends_with ~suffix:E2ee_keyring.password_required_message message ->
    { current with new_graph_password_required = true }
  | SendCaptureEffect _ | SendTaskEffect _ ->
    { current with capture_confirmation = None }
  | SendAssetEffect (_, asset) ->
    let current = { current with capture_confirmation = None } in
    if List.exists (fun (candidate : composer_asset) -> candidate.uuid = asset.uuid) current.composer_assets then current
    else { current with composer_assets = current.composer_assets @ [asset] }
  | _ -> rollback_navigation_effect current eff

let resolve_successful_effect (current : logseq_model) eff _message =
  match eff with
  | SendCaptureEffect (id, _) | SendTaskEffect (id, _, _) ->
    { current with capture_confirmation = Some id }
  | SendAssetEffect (id, asset) ->
    {
      current with
      capture_confirmation = Some id;
      composer_assets =
        List.filter
          (fun (candidate : composer_asset) -> candidate.uuid <> asset.uuid)
          current.composer_assets;
    }
  | SignInEffect _ ->
    {
      current with
      authentication_state = "signedIn";
      authentication_error = None;
    }
  | OpenGraphEffect (_, graph_id) ->
    (match graph_by_id current.graphs graph_id with
     | Some selected ->
       {
         current with
         destination = JournalsDestination;
         graph_loading = false;
         selected_graph_id = Some graph_id;
         selected_graph = Some selected.name;
         recent_graph_ids = graph_id :: remove_string current.recent_graph_ids graph_id;
            }
     | None ->
       { current with destination = JournalsDestination; graph_loading = false })
  | UnlockGraphEffect _ ->
    { current with graph_password_open = false; graph_password = "" }
  | CreateGraphEffect _ ->
    {
      current with
      destination = JournalsDestination;
      create_graph_open = false;
      new_graph_name = "";
      new_graph_password = "";
      new_graph_password_confirmation = "";
      new_graph_password_required = false;
    }
  | DeleteLocalGraphEffect (_, graph_id) ->
    let deleting_selected =
      match current.selected_graph_id with
      | Some selected_id -> selected_id = graph_id
      | None -> false
    in
    {
      current with
      pending_graph_deletion = None;
      local_graph_ids = remove_string current.local_graph_ids graph_id;
      selected_graph_id =
        (if deleting_selected then None else current.selected_graph_id);
      selected_graph =
        (if deleting_selected then None else current.selected_graph);
    }
  | SignOutEffect _ ->
    {
      current with
      authentication_state = "signedOut";
      authentication_error = None;
      settings_open = false;
      settings_tabs_open = false;
      runtime_log_open = false;
    }
  | _ -> current


let enqueue_open_graph (current : logseq_model) graph_id =
  let loading = { current with graph_loading = true } in
  let id = loading.next_effect_id in
  enqueue_effect loading (OpenGraphEffect (id, graph_id))

let persist_settings_change current updated =
  if current_settings current = current_settings updated then updated
  else begin
    let id = updated.next_effect_id in
    enqueue_effect updated (SaveSettingsEffect (id, current_settings updated))
  end

let enqueue_close_search_effects current path =
  let rec loop index updated =
    if index < 0 then updated
    else begin
      let uuid = navigation_route_uuid (List.nth path index) in
      let id = updated.next_effect_id in
      loop (index - 1)
        (enqueue_effect updated (CloseSearchNodeEffect (id, uuid)))
    end
  in
  loop (List.length path - 1) current

let update_editing (current : logseq_model) uuid title caret =
  match current.outliner_editing with
  | Some editing ->
    if editing.editing_uuid = uuid then
      {
        current with
        outliner_editing =
          Some { editing_uuid = uuid; editing_title = title; caret_utf16_offset = caret };
      }
    else current
  | None -> current

let contains_row_ rows uuid =
  match row_index rows uuid with
  | Some _ -> true
  | None -> false

let splice_start rows (splice : outline_row_splice) =
  match splice.after_block_id with
  | Some uuid ->
    (match row_index rows uuid with
     | Some index -> Some (index + 1)
     | None ->
       (match splice.before_block_id with
        | Some before_uuid -> row_index rows before_uuid
        | None -> splice.splice_start))
  | None ->
    (match splice.before_block_id with
     | Some uuid -> row_index rows uuid
     | None -> splice.splice_start)

let apply_row_splice rows (splice : outline_row_splice) =
  match splice_start rows splice with
  | None -> rows
  | Some requested_start ->
    let start = min (max requested_start 0) (List.length rows) in
    let delete_end =
      min (start + max splice.delete_count 0) (List.length rows)
    in
    let inserted = splice.splice_rows in
    let prefix =
      sub_list 0 start rows
      |> List.filter (fun (row : outline_row) ->
             not (contains_row_ inserted row.row_uuid))
    in
    let suffix =
      sub_list delete_end (List.length rows) rows
      |> List.filter (fun (row : outline_row) ->
             not (contains_row_ inserted row.row_uuid))
    in
    prefix @ inserted @ suffix

let apply_row_splices rows splices =
  List.fold_left apply_row_splice rows splices

let merge_row_replacements rows replacements =
  List.map
    (fun (row : outline_row) ->
      match row_index replacements row.row_uuid with
      | Some index -> List.nth replacements index
      | None -> row)
    rows

let remove_search_effects effects =
  List.filter
    (fun eff ->
      match eff with
      | SearchNodesEffect _ | LoadSearchPageEffect _ -> false
      | _ -> true)
    effects

let remove_composer_draft_effects effects =
  List.filter
    (fun eff ->
      match eff with
      | PersistComposerDraftEffect _ -> false
      | _ -> true)
    effects

let remove_effect effects target =
  List.filter (fun eff -> effect_id eff <> target) effects

let editing_sync_state (current : logseq_model) =
  match current.sync_state with
  | OfflineState -> OfflineState
  | FailedState reason -> FailedState reason
  | _ -> SyncingState

let ui_session (current : logseq_model) =
  {
    graph_id = current.selected_graph_id;
    recent_graph_ids = current.recent_graph_ids;
    destination = current.destination;
    assets =
      List.fold_left
        (fun assets eff ->
          match eff with
          | SendAssetEffect (_, asset)
            when not (List.exists (fun (candidate : composer_asset) -> candidate.uuid = asset.uuid) assets) ->
            assets @ [asset]
          | _ -> assets)
        current.composer_assets
        (current.in_flight_effects @ current.pending_effects);
    composer_expanded = current.composer_expanded;
    search_open = current.search_open;
    query = current.search_query;
    app_path = current.app_navigation_path;
    search_path = current.search_navigation_path;
    selected_page_id =
      (match current.selected_page with
       | Some page -> Some page.uuid
       | None -> None);
    settings_open = current.settings_open;
  }

let restore_session_routes current paths search =
  List.fold_left
    (fun result route ->
      let uuid = navigation_route_uuid route in
      let id = result.next_effect_id in
      enqueue_effect result
        (if search then OpenSearchNodeEffect (id, uuid)
         else OpenAppNodeEffect (id, uuid)))
    current paths

let restore_ui_session (current : logseq_model) (session : ui_session) =
  if
    session.graph_id = None
    || session.graph_id <> current.selected_graph_id
  then current
  else begin
    let restored =
      {
        current with
        destination = session.destination;
        recent_graph_ids = session.recent_graph_ids;
        composer_assets = session.assets;
        composer_expanded = session.composer_expanded;
        composer_autofocus = session.composer_expanded;
        search_open = session.search_open;
        search_query = session.query;
        app_navigation_path = session.app_path;
        search_navigation_path = session.search_path;
        settings_open = session.settings_open;
      }
    in
    let selected =
      match session.selected_page_id with
      | Some uuid ->
        enqueue_effect restored
          (SelectSidebarPageEffect (restored.next_effect_id, uuid))
      | None -> restored
    in
    let app_restored = restore_session_routes selected session.app_path false in
    let searched =
      if session.search_open && session.query <> "" then
        enqueue_effect
          { app_restored with search_loading = true }
          (SearchNodesEffect (app_restored.next_effect_id, session.query))
      else app_restored
    in
    let routed = restore_session_routes searched session.search_path true in
    match session.destination with
    | FlashcardsDestination ->
      enqueue_effect routed
        (LoadFlashcardsEffect routed.next_effect_id)
    | _ -> routed
  end

let hydrate_rows content rows =
  let by_id = Hashtbl.create (List.length content) in
  List.iter (fun (row : outline_row) -> Hashtbl.replace by_id row.row_uuid row) content;
  List.map (fun (row : outline_row) ->
    match Hashtbl.find_opt by_id row.row_uuid with
    | None -> row
    | Some value -> { value with depth = row.depth; has_children = row.has_children;
        is_collapsed = row.is_collapsed; opens_as_page = row.opens_as_page;
        (* Body hydration can omit ancestry already supplied by a reference projection. *)
        row_breadcrumbs = (if value.row_breadcrumbs = [] then row.row_breadcrumbs else value.row_breadcrumbs);
        row_breadcrumb = (if value.row_breadcrumb = "" then row.row_breadcrumb else value.row_breadcrumb) }) rows

let retain_shell_contents previous rows =
  let by_id = Hashtbl.create (List.length previous) in
  List.iter (fun (row : outline_row) -> Hashtbl.replace by_id row.row_uuid row) previous;
  List.map (fun (row : outline_row) ->
    if row.row_loaded then row else
      match Hashtbl.find_opt by_id row.row_uuid with
      | None -> row
      | Some cached -> { cached with row_loaded = false; depth = row.depth;
          has_children = row.has_children; is_collapsed = row.is_collapsed;
          opens_as_page = row.opens_as_page; page_id = row.page_id;
          journal_title = row.journal_title; journal_day = row.journal_day }) rows

let wide_content_breakpoint = 600

let sidebar_after_navigation current =
  current.sidebar_open && current.viewport_width >= wide_content_breakpoint

let rec update (current : logseq_model) action =
  match action with
  | SaveUISession ->
    enqueue_effect current
      (PersistUISessionEffect (current.next_effect_id, ui_session current))
  | RestoreUISession session -> restore_ui_session current session
  | SelectGraph graph_name ->
    { current with selected_graph = Some graph_name }
  | BeginSync -> { current with sync_state = SyncingState }
  | SyncSucceeded -> { current with sync_state = SyncedState }
  | SyncFailed reason -> { current with sync_state = FailedState reason }
  | OpenSearch -> { current with search_open = true }
  | EnsureOutlinerRows ids ->
    let requested = Hashtbl.create 32 in
    List.iter (function HydrateOutlinerRowsEffect (_, ids) ->
      List.iter (fun id -> Hashtbl.replace requested id ()) ids | _ -> ())
      (current.pending_effects @ current.in_flight_effects);
    let ids = List.filter (fun id ->
      if Hashtbl.mem requested id then false
      else (Hashtbl.add requested id (); true)) ids in
    if ids = [] then current
    else enqueue_effect current (HydrateOutlinerRowsEffect (current.next_effect_id, ids))
  | LoadMoreSearchResults ->
    if not current.search_has_more || current.search_loading || current.search_loading_more
       || String_kit.is_blank current.search_query then current
    else enqueue_effect { current with search_loading_more = true }
      (LoadSearchPageEffect (current.next_effect_id, current.search_query, current.search_result_count))
  | ChangeSearchQuery query when query = current.search_query -> current
  | ChangeSearchQuery query ->
    let pending = remove_search_effects current.pending_effects in
    if String_kit.is_blank query then
      {
        current with
        search_query = query;
        search_result_pages = [];
        search_result_count = 0;
        search_loading = false;
        search_loading_more = false;
        search_has_more = false;
        pending_effects = pending;
      }
    else begin
      let id = current.next_effect_id in
      {
        current with
        search_query = query;
        search_loading = true;
        search_result_pages = [];
        search_result_count = 0;
        search_has_more = false;
        search_loading_more = false;
        pending_effects = pending @ [ SearchNodesEffect (id, query) ];
        next_effect_id = id + 1;
        effect_error = None;
      }
    end
  | ApplySearchResults (query, results) ->
    if query = current.search_query then
      { current with search_result_pages = [results]; search_result_count = List.length results; search_loading = false; search_loading_more = false; search_has_more = false }
    else current
  | ApplyCoreSnapshot projection ->
    let applied = apply_core_snapshot current projection in
    (* Uploads need the existing subscription to receive acknowledgements. *)
    let updated =
      if not projection.is_pending_sync_patch && not projection.is_pending_sync_projection
        && (applied.has_pending_semantic_operations || applied.has_pending_sync_request)
        && not (List.exists (function SyncNowEffect _ | SyncPendingEffect _ -> true | _ -> false)
          (applied.pending_effects @ applied.in_flight_effects))
      then enqueue_effect applied (SyncPendingEffect applied.next_effect_id)
      else applied in
    (match projection.pending_reference_uuid with
     | Some uuid when not (List.exists (function
         | LoadPageReferencesEffect (_, candidate) -> candidate = uuid
         | _ -> false) (updated.pending_effects @ updated.in_flight_effects)) ->
       enqueue_effect updated (LoadPageReferencesEffect (updated.next_effect_id, uuid))
     | _ -> updated)
  | BeginOutlinerEdit uuid ->
    let id = current.next_effect_id in
    enqueue_effect current (TapOutlinerBlockEffect (id, uuid))
  | ChangeOutlinerText (uuid, title, caret) ->
    let updated =
      {
        (update_editing current uuid title caret) with
        sync_state = editing_sync_state current;
        outliner_autocomplete_candidates =
          reference_autocomplete_candidates current;
      }
    in
    let id = updated.next_effect_id in
    enqueue_effect { updated with pending_effects =
      remove_trailing_outliner_inputs updated.pending_effects uuid }
      (ChangeOutlinerTextEffect (id, uuid, title, caret))
  | ReturnOutlinerEditor (uuid, title, caret) ->
    let updated = update_editing current uuid title caret in
    let id = updated.next_effect_id in
    enqueue_effect updated
      (ReturnOutlinerEditorEffect (id, uuid, title, caret))
  | BackspaceOutlinerEditor (uuid, title, selection_length) ->
    let id = current.next_effect_id in
    enqueue_effect current
      (BackspaceOutlinerEditorEffect (id, uuid, title, selection_length))
  | MoveOutlinerCaret (uuid, caret) ->
    let title =
      match current.outliner_editing with
      | Some editing -> editing.editing_title
      | None -> ""
    in
    let updated = update_editing current uuid title caret in
    let id = updated.next_effect_id in
    let pending = remove_trailing_outliner_inputs updated.pending_effects uuid in
    let has_pending_text = List.exists
      (fun eff -> change_outliner_text_effect_for_ eff uuid)
      (sub_list (List.length pending) (List.length updated.pending_effects) updated.pending_effects) in
    enqueue_effect { updated with pending_effects = pending;
      outliner_autocomplete_candidates =
        reference_autocomplete_candidates current }
      (if has_pending_text then ChangeOutlinerTextEffect (id, uuid, title, caret)
       else MoveOutlinerCaretEffect (id, uuid, caret))
  | ToggleOutlinerCollapsed uuid ->
    let id = current.next_effect_id in
    enqueue_effect current (ToggleOutlinerCollapsedEffect (id, uuid))
  | LongPressOutlinerBlock uuid ->
    let id = current.next_effect_id in
    enqueue_effect current (LongPressOutlinerBlockEffect (id, uuid))
  | BeginOutlinerDrag uuid ->
    if string_vector_contains_ current.outliner_selected_block_ids uuid then
      current
    else begin
      let id = current.next_effect_id in
      enqueue_effect current (LongPressOutlinerBlockEffect (id, uuid))
    end
  | DropOutlinerBlocks (target_uuid, placement) ->
    let id = current.next_effect_id in
    enqueue_effect current
      (DropOutlinerBlocksEffect (id, target_uuid, placement))
  | ConfirmOutlinerDelete ->
    enqueue_effect current (ConfirmOutlinerDeleteEffect current.next_effect_id)
  | PerformOutlinerToolbarAction action ->
    (* The core commits the draft before publishing editor dismissal. Removing
       it here lets a queued typing response remount and refocus the editor. *)
    let updated =
      if action = "task" then
        { current with sync_state = editing_sync_state current }
      else current
    in
    let id = updated.next_effect_id in
    enqueue_effect updated (OutlinerToolbarEffect (id, action))
  | ChooseOutlinerAutocomplete value ->
    (match current.outliner_editing with
     | Some _ ->
       let id = current.next_effect_id in
       enqueue_effect current
         (ChooseOutlinerAutocompleteEffect (id, value))
     | None -> current)
  | OpenOutlinerAsset uuid ->
    (match row_index current.outliner_rows uuid with
     | Some index ->
       let row = List.nth current.outliner_rows index in
       if row.is_asset then
         match row.local_path with
         | Some path ->
           let id = current.next_effect_id in
           let asset_type =
             match row.asset_type with
             | Some value -> value
             | None -> "application/octet-stream"
           in
           enqueue_effect current
             (PresentAssetEffect (id, row.row_title, asset_type, path))
         | None -> current
       else current
     | None -> current)
  | ResolveAssetPreview (title, path) ->
    {
      current with
      asset_preview =
        Some { preview_title = title; preview_path = path };
    }
  | DismissAssetPreview -> { current with asset_preview = None }
  | DismissCaptureConfirmation id ->
    if current.capture_confirmation = Some id then
      { current with capture_confirmation = None }
    else current
  | CloseSearch ->
    let path = current.search_navigation_path in
    let editing_ended =
      if path = [] then current else cancel_outliner_editing current
    in
    let closed =
      {
        editing_ended with
        search_open = false;
        search_query = "";
        search_result_pages = [];
        search_result_count = 0;
        search_loading = false;
        search_loading_more = false;
        search_has_more = false;
        pending_effects = remove_search_effects current.pending_effects;
        search_navigation_path = [];
      }
    in
    enqueue_close_search_effects closed path
  | ExpandComposer ->
    { current with composer_expanded = true; composer_autofocus = true }
  | FocusComposer ->
    (* autofocus is an edge-triggered focus request: toggling guarantees a
       prop diff (and therefore a refocus edge) even when the flag already
       reads true while the field is unfocused *)
    { current with composer_autofocus = not current.composer_autofocus }
  | ApplyComposerDraft draft -> { current with composer_draft = draft }
  | ChangeComposerDraft draft ->
    let updated =
      {
        current with
        composer_draft = draft;
        composer_autofocus = false;
        pending_effects =
          remove_composer_draft_effects current.pending_effects;
      }
    in
    let id = updated.next_effect_id in
    enqueue_effect updated (PersistComposerDraftEffect (id, draft))
  | DismissComposer ->
    { current with composer_expanded = false; composer_autofocus = false }
  | StageComposerAsset asset ->
    {
      current with
      composer_expanded = true;
      composer_autofocus = true;
      composer_assets = current.composer_assets @ [ asset ];
    }
  | RemoveComposerAsset uuid ->
      {
        current with
        composer_assets =
          List.filter
            (fun (asset : composer_asset) -> asset.uuid <> uuid)
            current.composer_assets;
      }
  | SendComposer ->
    begin
      let assets = current.composer_assets in
      let submission = String.trim current.composer_draft in
      let current = { current with composer_assets = [];
        capture_confirmation =
          (if submission = "" && assets = [] then current.capture_confirmation else None) } in
      let with_text =
        if submission = "" then current
        else begin
          let cleared =
            {
              current with
              composer_expanded = true;
              composer_draft = "";
              composer_autofocus = true;
              pending_effects =
                remove_composer_draft_effects current.pending_effects;
            }
          in
          let persisted =
            enqueue_effect cleared
              (PersistComposerDraftEffect (cleared.next_effect_id, ""))
          in
          enqueue_effect persisted
            (match current.selected_task_status with
             | Some status ->
               SendTaskEffect (persisted.next_effect_id, submission, status)
             | None ->
               SendCaptureEffect (persisted.next_effect_id, submission))
        end
      in
      List.fold_left
        (fun updated asset ->
          enqueue_effect updated
            (SendAssetEffect (updated.next_effect_id, asset)))
        with_text assets
    end
  | DequeueEffect id ->
    let pending = current.pending_effects in
    (match effect_with_id pending id with
     | Some eff ->
       {
         current with
         pending_effects = remove_effect pending id;
         in_flight_effects = current.in_flight_effects @ [ eff ];
       }
     | None -> current)
  | ResolveEffect (id, succeeded, message) ->
    (match effect_with_id current.in_flight_effects id with
     | Some eff ->
       let resolved_current =
         if succeeded then resolve_successful_effect current eff message
         else resolve_failed_effect current eff message
       in
       let resolved_current = match eff with
         | SearchNodesEffect (_, query) when not succeeded && query = current.search_query ->
           { resolved_current with search_loading = false }
         | LoadSearchPageEffect (_, query, _) when not succeeded && query = current.search_query ->
           { resolved_current with search_loading_more = false }
         | _ -> resolved_current in
       let resolved = {
         resolved_current with
         in_flight_effects = remove_effect current.in_flight_effects id;
         outliner_selection_revision =
           (match succeeded, eff with
            | true, ChooseOutlinerAutocompleteEffect _ -> current.outliner_selection_revision + 1
            | _ -> current.outliner_selection_revision);
         effect_error =
           (if succeeded || (match eff with
              | CreateGraphEffect _ -> String.ends_with ~suffix:E2ee_keyring.password_required_message message
              | _ -> false)
            then None else Some message);
         last_core_response =
           (if succeeded then Some message else current.last_core_response);
       } in
       let resolved = match succeeded, eff, resolved.sync_state, resolved.outliner_editing with
         | true, SaveOutlinerEditingEffect (_, uuid), SyncingState, Some editing
           when editing.editing_uuid = uuid
             && not resolved.has_pending_semantic_operations
             && not resolved.has_pending_sync_request
             && not (change_outliner_text_active_ resolved uuid) ->
           { resolved with sync_state = SyncedState }
         | _ -> resolved in
       let edited_uuid = match eff with
         | ChangeOutlinerTextEffect (_, uuid, _, _) -> Some uuid
         | BackspaceOutlinerEditorEffect (_, uuid, _, _) -> Some uuid
         | ChooseOutlinerAutocompleteEffect _ -> Option.map (fun editing -> editing.editing_uuid) resolved.outliner_editing
         | _ -> None in
       let saved = match succeeded, edited_uuid, resolved.outliner_editing with
         | true, Some uuid, Some editing
           when editing.editing_uuid = uuid && resolved.outliner_autocomplete = None
             && not (List.exists cancels_outliner_autosave resolved.pending_effects) ->
           let ready = cancel_outliner_autosave resolved in
           enqueue_effect ready (SaveOutlinerEditingEffect (ready.next_effect_id, uuid))
         | _ -> resolved in
       let needs_sync = succeeded && (saved.has_pending_semantic_operations || saved.has_pending_sync_request)
         && (match eff with SyncNowEffect _ | SyncPendingEffect _ -> false | _ -> true)
         && not (List.exists (function SyncNowEffect _ | SyncPendingEffect _ -> true | _ -> false)
              (saved.pending_effects @ saved.in_flight_effects)) in
       if needs_sync then enqueue_effect saved (SyncPendingEffect saved.next_effect_id) else saved
     | None -> current)
  | OpenAttachmentPicker ->
    { current with attachment_picker_open = true }
  | CloseAttachmentPicker ->
    { current with attachment_picker_open = false }
  | ChooseAttachment kind ->
    if valid_attachment_kind_ kind then begin
      let updated = { current with attachment_picker_open = false } in
      let id = updated.next_effect_id in
      enqueue_effect updated (PresentAttachmentEffect (id, kind))
    end
    else current
  | OpenTaskStatusPicker ->
    { current with task_status_picker_open = true }
  | CloseTaskStatusPicker ->
    { current with task_status_picker_open = false }
  | ChooseTaskStatus uuid ->
    (match task_status_by_id current.task_statuses uuid with
     | Some status ->
       {
         current with
         selected_task_status = Some status;
         task_status_picker_open = false;
       }
     | None -> current)
  | ClearTaskStatus ->
    {
      current with
      selected_task_status = None;
      task_status_picker_open = false;
    }
  | RequestAppNode uuid ->
    let path = current.app_navigation_path in
    let requested = request_route path (NodeRoute uuid) in
    if path = requested then current
    else begin
      let updated =
        {
          (publish_navigation_preview (cancel_outliner_editing current) uuid) with
          app_navigation_path = requested;
        }
      in
      let id = updated.next_effect_id in
      enqueue_effect updated (OpenAppNodeEffect (id, uuid))
    end
  | ResolveAppNode (uuid, resolved) ->
    let updated =
      {
        current with
        app_navigation_path =
          resolve_route current.app_navigation_path (NodeRoute uuid)
            resolved;
      }
    in
    if resolved then updated
    else
      {
        updated with
        app_navigation_previews =
          remove_node_projection updated.app_navigation_previews uuid;
      }
  | BackAppNavigation count ->
    if current.outliner_selected_block_ids <> [] then
      let id = current.next_effect_id in
      enqueue_effect current (OutlinerToolbarEffect (id, "unselect"))
    else back_app_navigation current count
  | RequestSearchResult uuid
  | RequestSearchNode uuid ->
    let path = current.search_navigation_path in
    let requested = request_route path (NodeRoute uuid) in
    if path = requested then current
    else begin
      let updated =
        {
          (cancel_outliner_editing current) with
          search_navigation_path = requested;
        }
      in
      let id = updated.next_effect_id in
      enqueue_effect updated
        (match action with
         | RequestSearchResult _ -> OpenSearchResultEffect (id, uuid)
         | _ -> OpenSearchNodeEffect (id, uuid))
    end
  | ResolveSearchNode (uuid, resolved) ->
    {
      current with
      search_navigation_path =
        resolve_route current.search_navigation_path (NodeRoute uuid)
          resolved;
    }
  | BackSearchNavigation count -> back_search_navigation current count
  | AddRootBlock uuid ->
    let id = current.next_effect_id in
    enqueue_effect current (AddRootBlockEffect (id, uuid))
  | LoadOlderJournals ->
    if current.graph_loading || load_older_journals_active_ current then current
    else begin
      let id = current.next_effect_id in
      enqueue_effect current (LoadOlderJournalsEffect id)
    end
  | ApplyViewportWidth width -> { current with viewport_width = max 0 width }
  | OpenSidebar -> { current with sidebar_open = true }
  | CloseSidebar ->
    { current with sidebar_open = false; graph_menu_open = false }
  | OpenGraphMenu -> { current with graph_menu_open = true }
  | DismissGraphMenu -> { current with graph_menu_open = false }
  | SelectSidebarGraph graph_id ->
    (match graph_by_id current.graphs graph_id with
     | Some graph ->
       if graph.is_ready then begin
         let updated =
           {
             (cancel_outliner_editing (return_to_app_root current)) with
             sidebar_open = sidebar_after_navigation current;
             graph_menu_open = false;
           }
         in
         let selected =
           match updated.selected_graph_id with
           | Some selected_id -> selected_id = graph_id
           | None -> false
         in
         if selected then
           let id = updated.next_effect_id in
           enqueue_effect updated (ClearSelectedPageEffect id)
         else enqueue_open_graph updated graph_id
       end
       else current
     | None -> current)
  | SelectSidebarPage uuid ->
    let reusable = current.selected_page_ready && current.node_routes = []
      && current.app_navigation_path = [] && not current.search_open
      && current.outliner_editing = None && current.outliner_selected_block_ids = []
      && (match current.selected_page with Some page -> page.uuid = uuid | None -> false) in
    let updated =
      preview_sidebar_page
        {
          (cancel_outliner_editing (return_to_app_root current)) with
          sidebar_open = sidebar_after_navigation current;
          graph_menu_open = false;
          destination = JournalsDestination;
        }
        uuid
    in
    if reusable then updated
    else enqueue_effect updated (SelectSidebarPageEffect (updated.next_effect_id, uuid))
  | OpenQuickAction kind ->
    if not (kind = "capture" || kind = "audio" || kind = "journal") then
      current
    else begin
      let updated =
        {
          (cancel_outliner_editing current) with
          search_open = false;
          search_navigation_path = [];
          app_navigation_path = [];
          app_navigation_previews = [];
          settings_open = false;
          settings_tabs_open = false;
          runtime_log_open = false;
          sidebar_open = false;
          graph_menu_open = false;
          destination = JournalsDestination;
          composer_expanded = kind <> "journal";
          composer_autofocus = kind = "capture";
        }
      in
      let cleared =
        enqueue_effect updated
          (ClearSelectedPageEffect updated.next_effect_id)
      in
      if kind = "audio" then
        enqueue_effect cleared
          (PresentAttachmentEffect (cleared.next_effect_id, "audio"))
      else cleared
    end
  | ShowJournals ->
    let updated =
      {
        (cancel_outliner_editing (return_to_app_root current)) with
        sidebar_open = sidebar_after_navigation current;
        graph_menu_open = false;
        destination = JournalsDestination;
      }
    in
    let id = updated.next_effect_id in
    enqueue_effect updated (ClearSelectedPageEffect id)
  | ShowFlashcards ->
    let updated =
      {
        (cancel_outliner_editing (return_to_app_root current)) with
        sidebar_open = sidebar_after_navigation current;
        graph_menu_open = false;
        destination = FlashcardsDestination;
      }
    in
    let clear_id = updated.next_effect_id in
    let cleared =
      enqueue_effect updated (ClearSelectedPageEffect clear_id)
    in
    let load_id = cleared.next_effect_id in
    enqueue_effect cleared (LoadFlashcardsEffect load_id)
  | ShowGraphs ->
    {
      (cancel_outliner_editing (return_to_app_root current)) with
      sidebar_open = sidebar_after_navigation current;
      graph_menu_open = false;
      destination = GraphsDestination;
    }
  | ApplyLocalGraphIds graph_ids ->
    { current with local_graph_ids = graph_ids }
  | ApplyGraphLoading loading -> { current with graph_loading = loading }
  | RefreshGraphs ->
    if graph_refresh_active_ current then current
    else begin
      let id = current.next_effect_id in
      enqueue_effect current (RefreshGraphsEffect id)
    end
  | RequestOpenGraph graph_id ->
    (match graph_by_id current.graphs graph_id with
     | Some graph ->
       if graph.is_ready then
         enqueue_open_graph (cancel_outliner_editing current) graph_id
       else current
     | None -> current)
  | ChangeGraphPassword password ->
    { current with graph_password = password }
  | SubmitGraphPassword ->
    if
      String_kit.is_blank current.graph_password
      || graph_unlock_active_ current
    then current
    else begin
      let id = current.next_effect_id in
      enqueue_effect current
        (UnlockGraphEffect (id, current.graph_password))
    end
  | CancelGraphUnlock ->
    let cancelled =
      {
        current with
        graph_password_open = false;
        graph_password = "";
        effect_error = None;
        unlock_previous_graph_id = None;
      }
    in
    (match current.unlock_previous_graph_id with
     | Some previous_id when Some previous_id <> current.selected_graph_id ->
       enqueue_open_graph cancelled previous_id
     | _ -> cancelled)
  | OpenCreateGraph -> { current with create_graph_open = true }
  | DismissCreateGraph ->
    {
      current with
      create_graph_open = false;
      new_graph_name = "";
      new_graph_password = "";
      new_graph_password_confirmation = "";
      new_graph_password_required = false;
      new_graph_encrypted = true;
      effect_error = None;
    }
  | ChangeNewGraphName name -> { current with new_graph_name = name }
  | ToggleNewGraphEncrypted encrypted ->
    { current with new_graph_encrypted = encrypted }
  | ChangeNewGraphPassword password -> { current with new_graph_password = password }
  | ChangeNewGraphPasswordConfirmation password -> { current with new_graph_password_confirmation = password }
  | SubmitCreateGraph ->
    let name = String.trim current.new_graph_name in
    if name = "" || graph_create_active_ current
       || graph_creation_password_invalid_ current
    then current
    else begin
      let id = current.next_effect_id in
      enqueue_effect current
        (CreateGraphEffect (id, name, current.new_graph_encrypted,
          if current.new_graph_encrypted then current.new_graph_password else ""))
    end
  | RequestDeleteGraph graph_id ->
    if
      graph_local_ current graph_id
      && not (graph_delete_active_ current graph_id)
    then
      {
        current with
        pending_graph_deletion = graph_by_id current.graphs graph_id;
      }
    else current
  | CancelDeleteGraph -> { current with pending_graph_deletion = None }
  | ConfirmDeleteGraph ->
    (match current.pending_graph_deletion with
     | Some graph ->
       let updated = { current with pending_graph_deletion = None } in
       let id = updated.next_effect_id in
       enqueue_effect updated (DeleteLocalGraphEffect (id, graph.id))
     | None -> current)
  | ApplyAuthentication (state, error) ->
    if valid_authentication_state_ state then
      if state = "signedOut" && sign_in_active_ current then current
      else
        {
          current with
          authentication_state = state;
          authentication_error = error;
        }
    else current
  | SignIn ->
    if current.authentication_state = "signedOut" then begin
      let updated =
        {
          current with
          authentication_state = "signingIn";
          authentication_error = None;
        }
      in
      let id = updated.next_effect_id in
      enqueue_effect updated (SignInEffect id)
    end
    else current
  | ApplySettingsSnapshot settings ->
    {
      current with
      appearance = settings.appearance;
      language = settings.language;
      spell_check = settings.spell_check;
      auto_correction = settings.auto_correction;
      sidebar_tabs = normalize_sidebar_tabs settings.sidebar_tabs;
      base_url = settings.base_url;
      base_url_draft = settings.base_url;
      version = settings.version;
      revision = settings.revision;
    }
  | OpenConnectionMenu -> { current with connection_menu_open = true }
  | CloseConnectionMenu -> { current with connection_menu_open = false }
  | OpenSyncDetails -> { current with sync_details_open = true }
  | CloseSyncDetails -> { current with sync_details_open = false }
  | SyncNow ->
    if List.exists (function SyncNowEffect _ -> true | _ -> false)
      (current.pending_effects @ current.in_flight_effects) then current
    else enqueue_effect current (SyncNowEffect current.next_effect_id)
  | SetOutlinerTaskStatus (block_id, status_id) ->
    (match task_status_by_id current.task_statuses status_id with
     | Some status ->
       let updated =
         { current with sync_state = editing_sync_state current }
       in
       let id = updated.next_effect_id in
       enqueue_effect updated
         (SetOutlinerTaskStatusEffect (id, block_id, status))
     | None -> current)
  | ToggleActivePageFavorite ->
    (match active_page current with
     | Some page ->
       let updated = { current with connection_menu_open = false } in
       let id = updated.next_effect_id in
       enqueue_effect updated
         (SetPageFavoriteEffect
            (id, page.uuid, not (page_is_favorite_ current page.uuid)))
     | None -> current)
  | ShareActivePage ->
    (match active_page current with
     | Some page ->
       let updated = { current with connection_menu_open = false } in
       let id = updated.next_effect_id in
       enqueue_effect updated
         (PresentPageShareEffect
            ( id
            , page_share_text page current.outliner_rows
            , page_share_asset_paths current.outliner_rows ))
     | None -> current)
  | RequestDeleteActivePage ->
    (match active_page current with
     | Some page ->
       {
         current with
         connection_menu_open = false;
         pending_page_deletion = Some page;
       }
     | None -> current)
  | CancelDeleteActivePage ->
    { current with pending_page_deletion = None }
  | ConfirmDeleteActivePage ->
    (match current.pending_page_deletion with
     | Some page ->
       let updated = { current with pending_page_deletion = None } in
       let delete_id = updated.next_effect_id in
       let deleting =
         enqueue_effect updated (DeletePageEffect (delete_id, page.uuid))
       in
       if deleting.app_navigation_path = [] then
         let clear_id = deleting.next_effect_id in
         enqueue_effect deleting (ClearSelectedPageEffect clear_id)
       else begin
         let path = deleting.app_navigation_path in
         let route = List.nth path (List.length path - 1) in
         let closed = { deleting with app_navigation_path = pop_route path } in
         let close_id = closed.next_effect_id in
         enqueue_effect closed
           (CloseAppNodeEffect (close_id, navigation_route_uuid route))
       end
     | None -> current)
  | OpenJournalCalendar -> enqueue_effect current (PresentJournalCalendarEffect current.next_effect_id)
  | OpenSettings ->
    {
      current with
      graph_menu_open = false;
      connection_menu_open = false;
      settings_open = true;
      settings_tabs_open = false;
      settings_appearance_menu_open = false;
      settings_language_menu_open = false;
      runtime_log_open = false;
      base_url_draft = current.base_url;
    }
  | DismissSettings ->
    {
      current with
      settings_open = false;
      settings_tabs_open = false;
      settings_appearance_menu_open = false;
      settings_language_menu_open = false;
      runtime_log_open = false;
      base_url_draft = current.base_url;
    }
  | OpenSettingsTabs -> { current with settings_tabs_open = true }
  | BackSettings ->
    { current with settings_tabs_open = false; runtime_log_open = false }
  | OpenSettingsAppearanceMenu ->
    { current with settings_appearance_menu_open = true }
  | CloseSettingsAppearanceMenu ->
    { current with settings_appearance_menu_open = false }
  | ChangeAppearance appearance ->
    persist_settings_change current
      {
        current with
        appearance;
        settings_appearance_menu_open = false;
      }
  | OpenSettingsLanguageMenu ->
    { current with settings_language_menu_open = true }
  | CloseSettingsLanguageMenu ->
    { current with settings_language_menu_open = false }
  | ChooseSettingsLanguage language ->
    (match settings_language_by_id current.language_choices language with
     | Some choice ->
       persist_settings_change current
         {
           current with
           language = choice.id;
           settings_language_menu_open = false;
         }
     | None -> { current with settings_language_menu_open = false })
  | ToggleSpellCheck enabled ->
    persist_settings_change current { current with spell_check = enabled }
  | ToggleAutoCorrection enabled ->
    persist_settings_change current
      { current with auto_correction = enabled }
  | ToggleSidebarTab tab ->
    persist_settings_change current
      {
        current with
        sidebar_tabs = toggle_sidebar_tab current.sidebar_tabs tab;
      }
  | MoveSidebarTab (tab, offset) ->
    persist_settings_change current
      {
        current with
        sidebar_tabs = move_sidebar_tab current.sidebar_tabs tab offset;
      }
  | ChangeBaseURL value -> { current with base_url_draft = value }
  | ApplySettings ->
    if valid_base_url_ current.base_url_draft then begin
      let applied =
        {
          current with
          base_url = String.trim current.base_url_draft;
          base_url_draft = String.trim current.base_url_draft;
        }
      in
      let id = applied.next_effect_id in
      enqueue_effect
        {
          applied with
          settings_open = false;
          settings_tabs_open = false;
          settings_language_menu_open = false;
          runtime_log_open = false;
        }
        (SaveSettingsEffect (id, current_settings applied))
    end
    else current
  | ExportGraphDatabase ->
    let id = current.next_effect_id in
    enqueue_effect current (ExportGraphDatabaseEffect id)
  | OpenExternalURL url ->
    let id = current.next_effect_id in
    enqueue_effect current (OpenExternalURLEffect (id, url))
  | OpenRuntimeLog ->
    let updated = { current with runtime_log_open = true } in
    let id = updated.next_effect_id in
    enqueue_effect updated
      (RefreshRuntimeLogEffect
         ( id
         , updated.runtime_log_source
         , updated.runtime_log_errors_only
         , updated.runtime_log_newest_first ))
  | DismissRuntimeLog -> { current with runtime_log_open = false }
  | ToggleRuntimeLogErrors ->
    let updated =
      {
        current with
        runtime_log_errors_only = not current.runtime_log_errors_only;
      }
    in
    let id = updated.next_effect_id in
    enqueue_effect updated
      (RefreshRuntimeLogEffect
         ( id
         , updated.runtime_log_source
         , updated.runtime_log_errors_only
         , updated.runtime_log_newest_first ))
  | ToggleRuntimeLogOrder ->
    let updated =
      {
        current with
        runtime_log_newest_first = not current.runtime_log_newest_first;
      }
    in
    let id = updated.next_effect_id in
    enqueue_effect updated
      (RefreshRuntimeLogEffect
         ( id
         , updated.runtime_log_source
         , updated.runtime_log_errors_only
         , updated.runtime_log_newest_first ))
  | ToggleRuntimeLogSource ->
    let updated =
      {
        current with
        runtime_log_source =
          (if current.runtime_log_source = "ui" then "core" else "ui");
      }
    in
    let id = updated.next_effect_id in
    enqueue_effect updated
      (RefreshRuntimeLogEffect
         ( id
         , updated.runtime_log_source
         , updated.runtime_log_errors_only
         , updated.runtime_log_newest_first ))
  | ApplyRuntimeLog records -> { current with runtime_log_records = records }
  | RefreshRuntimeLog ->
    let id = current.next_effect_id in
    enqueue_effect current
      (RefreshRuntimeLogEffect
         ( id
         , current.runtime_log_source
         , current.runtime_log_errors_only
         , current.runtime_log_newest_first ))
  | CopyRuntimeLog ->
    let id = current.next_effect_id in
    enqueue_effect current
      (CopyRuntimeLogEffect (id, current.runtime_log_records))
  | RequestSignOut ->
    { current with pending_sign_out = true; settings_open = false }
  | CancelSignOut ->
    { current with pending_sign_out = false; settings_open = true }
  | SignOut ->
    let id = current.next_effect_id in
    enqueue_effect
      { current with pending_sign_out = false }
      (SignOutEffect id)
  | RevealFlashcardCloze ->
    { current with flashcard_cloze_revealed = true }
  | RevealFlashcardAnswer ->
    { current with flashcard_answer_revealed = true }
  | ReviewFlashcard rating ->
    (match first_flashcard_id current.flashcards with
     | Some uuid ->
       let id = current.next_effect_id in
       enqueue_effect current (ReviewFlashcardEffect (id, uuid, rating))
     | None -> current)

and apply_core_snapshot (current : logseq_model)
    (projection : core_projection) =
  if Option.is_some projection.reference_update then
    if projection.selected_graph_id <> current.selected_graph_id then current
    else
      let uuid, rows = Option.get projection.reference_update in
      let selected = Option.map (fun (page : sidebar_page) -> page.uuid) current.selected_page = Some uuid in
      { current with
        related_rows = (if selected && not current.selected_page_is_tag then rows else current.related_rows);
        linked_reference_rows = (if selected && current.selected_page_is_tag then rows else current.linked_reference_rows);
        node_routes = List.map (fun (route : node_projection) ->
          if route.node_uuid <> uuid then route
          else if route.node_is_tag then { route with node_linked_reference_rows = rows }
          else { route with node_related_rows = rows }) current.node_routes }
  else if projection.is_search_patch then
    if projection.selected_graph_id = current.selected_graph_id
       && projection.projection_search_query = current.search_query then
      (if projection.search_offset <> 0 && projection.search_offset <> current.search_result_count then current
       else { current with
         search_result_pages = (if projection.search_offset = 0 then [projection.search_results]
           else projection.search_results :: current.search_result_pages);
         search_result_count = projection.search_offset + List.length projection.search_results;
         search_loading = false; search_loading_more = false; search_has_more = projection.search_has_more })
    else current
  else if projection.is_outliner_content_patch then
    if projection.selected_graph_id <> current.selected_graph_id then current
    else
      let hydrate = hydrate_rows projection.hydrated_rows in
      { current with outliner_rows = hydrate current.outliner_rows;
        navigation_root_rows = hydrate current.navigation_root_rows;
        journal_outliner_rows = hydrate current.journal_outliner_rows;
        related_rows = hydrate current.related_rows;
        linked_reference_rows = hydrate current.linked_reference_rows;
        node_routes = List.map (fun (route : node_projection) ->
          { route with node_outliner_rows = hydrate route.node_outliner_rows;
            node_related_rows = hydrate route.node_related_rows;
            node_linked_reference_rows = hydrate route.node_linked_reference_rows }) current.node_routes }
  else
  if projection.is_graph_catalog_patch then
    {
      current with
      selected_graph = projection.graph_name;
      selected_graph_id = projection.selected_graph_id;
      graphs = projection.graphs;
      is_graph_encrypted = projection.is_graph_encrypted;
      is_graph_unlocked = projection.is_graph_unlocked;
    }
  else if projection.is_pending_sync_patch then
    {
      current with
      sync_state =
        (match current.sync_state with
         | OfflineState -> OfflineState
         | FailedState reason -> FailedState reason
         | _ ->
           if
             projection.has_pending_semantic_operations
             || projection.has_pending_sync_request
           then SyncingState
           else SyncedState);
      has_pending_semantic_operations =
        projection.has_pending_semantic_operations;
      has_pending_sync_request = projection.has_pending_sync_request;
    }
  else if projection.is_outliner_patch then begin
    let projected_rows =
      let rows = if projection.outliner_row_splices = [] then
        merge_row_replacements current.outliner_rows
          projection.outliner_rows
      else
        apply_row_splices current.outliner_rows
          projection.outliner_row_splices
      in
      hydrate_rows projection.hydrated_rows rows
    in
    let journal_rows =
      if
        current.node_routes = []
        &&
        (match current.selected_page with
         | None -> true
         | Some _ -> false)
      then projected_rows
      else current.journal_outliner_rows
    in
    {
      current with
      has_pending_semantic_operations =
        projection.has_pending_semantic_operations;
      has_pending_sync_request = projection.has_pending_sync_request;
      navigation_root_rows = (if current.node_routes = [] then projected_rows else current.navigation_root_rows);
      journal_outliner_rows = journal_rows;
      outliner_editing = snapshot_outliner_editing current projection;
      outliner_autocomplete = snapshot_autocomplete current projection;
      outliner_autocomplete_candidates =
        snapshot_autocomplete_candidates current projection;
      outliner_selected_block_ids =
        projection.projection_outliner_selected_block_ids;
      outliner_section_markers = journal_section_markers projected_rows;
      outliner_rows = projected_rows;
    }
  end
  else begin
    let sidebar = projection.sidebar in
    let selected_graph_changed =
      current.selected_graph_id <> projection.selected_graph_id
    in
    let active_projection_node_uuid =
      Option.map (fun (route : node_projection) -> route.node_uuid) (last_opt projection.node_routes)
    in
    (* Deferred references must not collapse a retained screen during navigation. *)
    let root_reference_pending =
      let selected = Option.map (fun (page : sidebar_page) -> page.uuid) sidebar.selected_page in
      not selected_graph_changed && selected <> None
      && selected = Option.map (fun (page : sidebar_page) -> page.uuid) current.selected_page
      && (projection.node_routes <> [] || projection.pending_reference_uuid = selected)
    in
    let projection_is_journal_home =
      projection.node_routes = []
      &&
      (match sidebar.selected_page with
       | None -> true
       | Some _ -> false)
    in
    let preserve_journal_window =
      projection_is_journal_home
      && current.journal_outliner_rows <> []
      && (not selected_graph_changed)
      && (not (journal_refresh_active_ current))
      &&
      (match current.outliner_editing with
       | None -> true
       | Some _ -> false)
    in
    let projected_rows =
      if preserve_journal_window then
        refresh_journal_window current.journal_outliner_rows
          projection.outliner_rows
      else projection.outliner_rows
    in
    (* Returning to the root uses its cache, not the outgoing node's rows. *)
    let previous_rows =
      if projection.node_routes = [] && current.node_routes <> [] then
        current.navigation_root_rows
      else current.outliner_rows
    in
    let projected_rows = if selected_graph_changed then projected_rows
      else retain_shell_contents previous_rows projected_rows in
    let journal_rows =
      if projection_is_journal_home then projected_rows
      else
        match sidebar.selected_page with
        | None ->
          if selected_graph_changed || journal_refresh_active_ current then
            projection.journal_outliner_rows
          else
            refresh_journal_window current.journal_outliner_rows
              projection.journal_outliner_rows
        | Some _ -> current.journal_outliner_rows
    in
    let journal_rows = if selected_graph_changed then journal_rows
      else retain_shell_contents current.journal_outliner_rows journal_rows in
    let has_older_journals =
      if preserve_journal_window then
        (* Import and sync can add history after the visible window was
           exhausted. Rows retained outside that window still need paging. *)
        current.has_older_journals || projection.has_older_journals
        || List.compare_lengths projection.outliner_rows projected_rows > 0
      else projection.has_older_journals
    in
    let card_changed =
      first_flashcard_id current.flashcards
      <> first_flashcard_id projection.flashcards
    in
    let local_graph_ids =
      match projection.selected_graph_id with
      | Some graph_id ->
        if string_vector_contains_ current.local_graph_ids graph_id then
          current.local_graph_ids
        else current.local_graph_ids @ [ graph_id ]
      | None -> current.local_graph_ids
    in
    let search_navigation_path =
      match last_opt projection.node_routes, last_opt current.search_navigation_path with
      | Some { node_scroll_target = Some target; node_uuid; _ }, Some (NodeRoute requested)
        when target = requested
             && List.length projection.node_routes =
                List.length current.app_navigation_path + List.length current.search_navigation_path ->
        pop_route current.search_navigation_path @ [NodeRoute node_uuid]
      | _ -> current.search_navigation_path
    in
    let updated =
      {
        current with
        search_navigation_path;
        selected_graph = projection.graph_name;
        selected_graph_id = projection.selected_graph_id;
        graphs = projection.graphs;
        local_graph_ids;
        is_graph_encrypted = projection.is_graph_encrypted;
        is_graph_unlocked = projection.is_graph_unlocked;
        sync_state =
          (if projection.sync_connected then
             if
               projection.has_pending_semantic_operations
               || projection.has_pending_sync_request
             then SyncingState
             else SyncedState
           else OfflineState);
        applied_server_t = projection.applied_server_t;
        has_pending_semantic_operations =
          projection.has_pending_semantic_operations;
        has_pending_sync_request = projection.has_pending_sync_request;
        favorites = sidebar.favorites;
        recent_pages = sidebar.recent_pages;
        selected_page = sidebar.selected_page;
        selected_page_ready = true;
        selected_page_is_tag = sidebar.selected_page_is_tag;
        selected_page_is_property = sidebar.selected_page_is_property;
        related_rows = (if root_reference_pending && not sidebar.selected_page_is_tag then current.related_rows
          else if selected_graph_changed then sidebar.related_rows else retain_shell_contents current.related_rows sidebar.related_rows);
        linked_reference_rows = (if root_reference_pending && sidebar.selected_page_is_tag then current.linked_reference_rows
          else if selected_graph_changed then sidebar.linked_reference_rows else retain_shell_contents current.linked_reference_rows sidebar.linked_reference_rows);
        task_statuses = available_task_statuses projection.task_statuses;
        flashcards = projection.flashcards;
        flashcard_cloze_revealed =
          (if card_changed then false else current.flashcard_cloze_revealed);
        flashcard_answer_revealed =
          (if card_changed then false else current.flashcard_answer_revealed);
        node_routes = (if selected_graph_changed then projection.node_routes else
          List.map (fun (route : node_projection) ->
            match List.find_opt (fun (previous : node_projection) -> previous.node_uuid = route.node_uuid) current.node_routes with
            | None -> route
            | Some previous ->
              let reference_pending = projection.pending_reference_uuid = Some route.node_uuid
                || active_projection_node_uuid <> Some route.node_uuid in
              { route with
                node_outliner_rows = retain_shell_contents previous.node_outliner_rows route.node_outliner_rows;
                node_related_rows = (if reference_pending && not route.node_is_tag then previous.node_related_rows
                  else retain_shell_contents previous.node_related_rows route.node_related_rows);
                node_linked_reference_rows = (if reference_pending && route.node_is_tag then previous.node_linked_reference_rows
                  else retain_shell_contents previous.node_linked_reference_rows route.node_linked_reference_rows) }) projection.node_routes);
        navigation_root_rows = (if projection.node_routes = [] then projected_rows
          else if selected_graph_changed then projection.journal_outliner_rows
          else retain_shell_contents current.navigation_root_rows projection.journal_outliner_rows);
        journal_outliner_rows = journal_rows;
        outliner_editing = snapshot_outliner_editing current projection;
        outliner_autocomplete = snapshot_autocomplete current projection;
        outliner_autocomplete_candidates =
          snapshot_autocomplete_candidates current projection;
        outliner_selected_block_ids =
          projection.projection_outliner_selected_block_ids;
        has_older_journals;
        outliner_section_markers = journal_section_markers projected_rows;
        outliner_rows = projected_rows;
      }
    in
    let searched =
      if projection.projection_search_query = current.search_query then
        {
          updated with
          search_result_pages = [projection.search_results];
          search_result_count = List.length projection.search_results;
          search_has_more = projection.search_has_more;
          search_loading = false;
          search_loading_more = false;
        }
      else updated
    in
    match projection.selected_graph_id with
    | None ->
      {
        searched with
        graph_password_open = false;
        graph_password = "";
      }
    | Some _ ->
      if projection.is_graph_unlocked then
        {
          searched with
          graph_password_open = false;
          graph_password = "";
        }
      else if selected_graph_changed && projection.is_graph_encrypted then
        {
          searched with
          graph_password_open = true;
          graph_password = "";
          effect_error = None;
          unlock_previous_graph_id = current.selected_graph_id;
        }
      else searched
  end
