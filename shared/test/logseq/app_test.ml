open Test_util

let property (runtime : Lui_runtime.application) node property_key =
  match Hashtbl.find_opt runtime.Lui_runtime.runtime_properties node with
  | Some properties -> Lui_protocol.Property_map.find_opt property_key properties
  | None -> None

let node (runtime : Lui_runtime.application) node_id =
  Hashtbl.find_opt runtime.Lui_runtime.mounted_nodes node_id

let children (runtime : Lui_runtime.application) node =
  match Hashtbl.find_opt runtime.Lui_runtime.runtime_children node with
  | Some children -> Lui_sequence.to_list children
  | None -> []

let property_string runtime node key =
  match property runtime node key with
  | Some (Lui_protocol.StringValue value) -> value
  | _ -> "<missing>"

let property_int runtime node key =
  match property runtime node key with
  | Some (Lui_protocol.IntValue value) -> value
  | _ -> -1

let property_bool runtime node key =
  match property runtime node key with
  | Some (Lui_protocol.BoolValue value) -> value
  | _ -> false

let property_float runtime node key =
  match property runtime node key with
  | Some (Lui_protocol.FloatValue value) -> value
  | _ -> -1.0

let extension_property application node property =
  let runtime = Lui_app.runtime application in
  match
    Hashtbl.find_opt runtime.Lui_runtime.runtime_extension_properties node
  with
  | Some properties -> Lui_protocol.String_map.find_opt property properties
  | None -> None

let extension_node application identifier =
  let runtime = Lui_app.runtime application in
  let nodes = runtime.Lui_runtime.runtime_extension_nodes in
  let limit = !(runtime.Lui_runtime.next_node_id) in
  let rec loop node =
    if node > limit then -1
    else if Hashtbl.find_opt nodes node = Some identifier then node
    else loop (node + 1)
  in
  loop 1

let rec descendant_with_node_kind runtime parent kind =
  if node runtime parent = Some kind then parent
  else
    let children = children runtime parent in
    let rec loop index =
      if index = List.length children then -1
      else
        let found =
          descendant_with_node_kind runtime (List.nth children index) kind
        in
        if found = -1 then loop (index + 1) else found
    in
    loop 0

let menu_item_with_text runtime menu_trigger text =
  let menu =
    descendant_with_node_kind runtime menu_trigger
      Lui_protocol.DropdownMenu
  in
  if menu = -1 then -1
  else
    let items = children runtime menu in
    let rec find items =
      match items with
      | [] -> -1
      | item :: rest ->
        if property_string runtime item Lui_protocol.TextValue = text then
          item
        else find rest
    in
    find items

let rec descendant_count_with_node_kind runtime parent kind =
  let children = children runtime parent in
  let own = if node runtime parent = Some kind then 1 else 0 in
  let rec loop index total =
    if index = List.length children then total
    else
      loop (index + 1)
        (total
        + descendant_count_with_node_kind runtime (List.nth children index)
            kind)
  in
  loop 0 own

let rec descendant_count_with_property_string runtime parent property expected
    =
  let children = children runtime parent in
  let own =
    if expected = property_string runtime parent property then 1 else 0
  in
  let rec loop index total =
    if index = List.length children then total
    else
      loop (index + 1)
        (total
        + descendant_count_with_property_string runtime
            (List.nth children index) property expected)
  in
  loop 0 own

let rec descendant_with_extension runtime application parent identifier =
  let extensions =
    (Lui_app.runtime application).Lui_runtime.runtime_extension_nodes
  in
  if Hashtbl.find_opt extensions parent = Some identifier then parent
  else
    let children = children runtime parent in
    let rec loop index =
      if index = List.length children then -1
      else
        let found =
          descendant_with_extension runtime application
            (List.nth children index) identifier
        in
        if found = -1 then loop (index + 1) else found
    in
    loop 0

let native_row application parent =
  descendant_with_extension (Lui_app.runtime application) application parent
    "outliner-block-row"

let native_row_payload application parent =
  match extension_property application (native_row application parent) "payload" with
  | Some (Lui_protocol.StringValue value) -> Yojson.Basic.from_string value
  | _ -> failwith "Native row payload missing"

let child_with_identifier runtime parent identifier =
  let children = children runtime parent in
  let rec loop index =
    if index = List.length children then -1
    else
      let child = List.nth children index in
      if identifier
         = property_string runtime child
             Lui_protocol.AccessibilityIdentifier
      then child
      else loop (index + 1)
  in
  loop 0

let child_index_with_identifier runtime parent identifier =
  let children = children runtime parent in
  let rec loop index =
    if index = List.length children then -1
    else if
      identifier
      = property_string runtime (List.nth children index)
          Lui_protocol.AccessibilityIdentifier
    then index
    else loop (index + 1)
  in
  loop 0

let rec descendant_with_identifier runtime parent identifier =
  let direct = child_with_identifier runtime parent identifier in
  if direct <> -1 then direct
  else
    let children = children runtime parent in
    let rec loop index =
      if index = List.length children then -1
      else
        let found =
          descendant_with_identifier runtime (List.nth children index)
            identifier
        in
        if found = -1 then loop (index + 1) else found
    in
    loop 0

let rec descendant_extension_containing_identifier runtime application parent
    extension_identifier descendant_identifier =
  let extensions =
    (Lui_app.runtime application).Lui_runtime.runtime_extension_nodes
  in
  let is_matching_extension =
    Hashtbl.find_opt extensions parent = Some extension_identifier
  in
  if
    is_matching_extension
    && descendant_with_identifier runtime parent descendant_identifier <> -1
  then parent
  else
    let children = children runtime parent in
    let rec loop index =
      if index = List.length children then -1
      else
        let found =
          descendant_extension_containing_identifier runtime application
            (List.nth children index) extension_identifier
            descendant_identifier
        in
        if found = -1 then loop (index + 1) else found
    in
    loop 0

let rec parent_with_child_identifier runtime parent identifier =
  if child_with_identifier runtime parent identifier <> -1 then parent
  else
    let children = children runtime parent in
    let rec loop index =
      if index = List.length children then -1
      else
        let found =
          parent_with_child_identifier runtime (List.nth children index)
            identifier
        in
        if found = -1 then loop (index + 1) else found
    in
    loop 0

let rec descendant_count_with_identifier runtime parent identifier =
  let own =
    if identifier
       = property_string runtime parent
           Lui_protocol.AccessibilityIdentifier
    then 1
    else 0
  in
  let children = children runtime parent in
  let rec loop index total =
    if index = List.length children then total
    else
      loop (index + 1)
        (total
        + descendant_count_with_identifier runtime (List.nth children index)
            identifier)
  in
  loop 0 own

let descendant_enabled runtime parent identifier =
  let node = descendant_with_identifier runtime parent identifier in
  if node = -1 then None
  else
    match property runtime node Lui_protocol.Enabled with
    | Some (Lui_protocol.BoolValue enabled) -> Some enabled
    | _ -> None

let application_shell_root runtime application =
  let runtime_root = Lui_app.root_node application in
  let shell =
    descendant_with_identifier runtime runtime_root "application.shell"
  in
  if shell = -1 then runtime_root else shell

let main_root runtime application =
  let runtime_root = Lui_app.root_node application in
  let shell_root = application_shell_root runtime application in
  let picker_parent =
    parent_with_child_identifier runtime shell_root "screen.graph-picker"
  in
  let stack = List.nth (children runtime shell_root) 0 in
  let stack_children = children runtime stack in
  let container =
    List.nth stack_children (List.length stack_children - 1)
  in
  let extensions =
    (Lui_app.runtime application).Lui_runtime.runtime_extension_nodes
  in
  if picker_parent <> -1 then picker_parent
  else if Hashtbl.find_opt extensions container = Some "native-navigation-stack"
  then begin
    let wrapper = List.nth (children runtime container) 0 in
    let search = List.nth (children runtime wrapper) 0 in
    if Hashtbl.find_opt extensions search = Some "native-search-presentation"
    then begin
      let presented =
        extension_property application search "presented"
        = Some (Lui_protocol.BoolValue true)
      in
      List.nth (children runtime search) (if presented then 1 else 0)
    end
    else wrapper
  end
  else runtime_root

let native_bottom_chrome runtime application =
  let navigation = extension_node application "native-navigation-stack" in
  List.nth (children runtime navigation) 5

let empty_sidebar_projection () =
  {
    Model.favorites = [];
    recent_pages = [];
    selected_page = None;
    selected_page_is_tag = false;
    selected_page_is_property = false;
    related_rows = [];
    linked_reference_rows = [];
  }

let node_projection uuid page_uuid title related_rows linked_reference_rows =
  {
    Model.node_uuid = uuid;
    node_page_uuid = page_uuid;
    node_title = title;
    node_breadcrumbs = []; node_scroll_target = None;
    node_is_tag = false;
    node_is_property = false;
    node_outliner_rows = [];
    node_related_rows = related_rows;
    node_linked_reference_rows = linked_reference_rows;
    node_outliner_editing = None;
    node_outliner_autocomplete = None;
    node_outliner_autocomplete_candidates = [];
    node_outliner_selected_block_ids = [];
  }

let empty_core_projection () =
  {
    Model.graph_name = None;
    selected_graph_id = None;
    graphs = [];
    is_graph_encrypted = false;
    is_graph_unlocked = false;
    sidebar = empty_sidebar_projection ();
    task_statuses = [];
    flashcards = [];
    sync_connected = false;
    applied_server_t = None;
    has_pending_semantic_operations = false;
    has_pending_sync_request = false;
    is_pending_sync_patch = false;
    is_graph_catalog_patch = false;
    projection_search_query = "";
    search_results = [];
    node_routes = [];
    journal_outliner_rows = [];
    projection_outliner_editing = None;
    projection_outliner_autocomplete = None;
    projection_outliner_autocomplete_candidates = [];
    projection_outliner_selected_block_ids = [];
    outliner_rows = [];
    has_older_journals = false;
    is_outliner_patch = false;
    is_outliner_content_patch = false;
    reference_update = None;
    pending_reference_uuid = None;
    hydrated_rows = [];
    is_search_patch = false;
    outliner_row_splices = [];
  }

let apply_core_snapshot graph_name sidebar flashcards sync_connected
    search_query search_results node_routes outliner_editing
    outliner_autocomplete outliner_autocomplete_candidates
    outliner_selected_block_ids outliner_rows is_outliner_patch
    outliner_row_splices =
  Model.ApplyCoreSnapshot
    {
      (empty_core_projection ()) with
      graph_name;
      selected_graph_id = Some "test-graph";
      sidebar;
      flashcards;
      sync_connected;
      projection_search_query = search_query;
      search_results;
      node_routes;
      projection_outliner_editing = outliner_editing;
      projection_outliner_autocomplete = outliner_autocomplete;
      projection_outliner_autocomplete_candidates =
        outliner_autocomplete_candidates;
      projection_outliner_selected_block_ids = outliner_selected_block_ids;
      outliner_rows;
      is_outliner_patch;
      outliner_row_splices;
    }

let flashcard_answer uuid index text =
  {
    Model.answer_uuid = uuid;
    answer_index = index;
    answer_text = text;
  }

let flashcard uuid question_hidden question_revealed answer_rows has_cloze =
  {
    Model.flashcard_uuid = uuid;
    question_hidden;
    question_revealed;
    answer_rows;
    has_cloze;
  }

let graph id name encrypted ready =
  {
    Model.id;
    name;
    is_encrypted = encrypted;
    is_ready = ready;
  }

let journal_outline_row uuid page_id title journal_title journal_day depth =
  {
    Model.row_uuid = uuid;
    row_loaded = true;
    row_title = title;
    markup_json = "[]";
    youtube_target_url = None;
    row_breadcrumb = "";
    row_breadcrumbs = [];
    opens_as_page = false;
    depth;
    has_children = false;
    is_collapsed = false;
    is_asset = false;
    asset_type = None;
    local_path = None;
    row_priority = None;
    row_status = None;
    tags = [];
    sync_status = None;
    page_id;
    journal_title = Some journal_title;
    journal_day = Some journal_day;
  }

let task_status uuid ident title icon_type icon_id icon_color =
  {
    Model.uuid;
    ident;
    title;
    icon_type;
    icon_id;
    icon_color;
  }

let settings tabs =
  {
    Model.appearance = "system";
    language = "system";
    spell_check = true;
    auto_correction = true;
    sidebar_tabs = tabs;
    base_url = "https://api.logseq.com";
    version = "1.0";
    revision = "abc123";
  }

let runtime_record id level source message =
  {
    Model.id;
    level;
    source;
    timestamp = "12:00";
    message;
  }

let ios_backend () =
  Native_bridge.backend
    (Lui_protocol.profile Lui_protocol.IOS Lui_protocol.SwiftUIHost)

let kotlin_backend () =
  Native_bridge.backend
    (Lui_protocol.profile Lui_protocol.AndroidOS Lui_protocol.KotlinHost)

let start application = ignore (Lui_app.start application)
let send application action = ignore (Lui_app.send application action)
let flush application = ignore (Lui_app.flush application)
let dispatch application event =
  ignore (Lui_app.dispatch_event application event)

(* TESTS *)

let contains sub s =
  let sub_len = String.length sub in
  let rec loop index =
    if index + sub_len > String.length s then false
    else if String.sub s index sub_len = sub then true
    else loop (index + 1)
  in
  loop 0

let sync_checkpoint_encoding_is_lg_owned () =
  let checkpoint = Sync_checkpoint.create "graph-1" "65.33" 48192 in
  let restored =
    Sync_checkpoint.decode (Sync_checkpoint.encode checkpoint)
  in
  check_eq ~msg:"LG sync checkpoint codec should round-trip" restored
    (Ok checkpoint);
  check_eq ~msg:"LG sync checkpoint codec should reject negative cursors"
    (Sync_checkpoint.decode
       (Sync_checkpoint.encode
          (Sync_checkpoint.create "graph-1" "65.33" (-1))))
    (Error "invalid graph sync checkpoint");
  check_eq ~msg:"LG sync checkpoint codec should reject non-map payloads"
    (Sync_checkpoint.decode "[]")
    (Error "graph sync checkpoint must be a Transit map")

let flashcard_state_codec_is_lg_owned () =
  check_eq ~msg:"flashcard ratings should use LG keywords"
    (Flashcards.rating_name Flashcards.Good)
    "good";
  check_eq ~msg:"flashcard rating names should stay JSON-friendly"
    (Flashcards.rating_name Flashcards.Good)
    "good";
  check_eq ~msg:"flashcard state parsing should use LG keywords"
    (Flashcards.state_of_keyword "review")
    (Some Flashcards.Review);
  check_eq ~msg:"flashcard state names should stay JSON-friendly"
    (Flashcards.state_name Flashcards.Review)
    "review";
  let now = 1776000000000 in
  let original =
    {
      Flashcards.due = now - 86400000;
      stability = 4.2;
      difficulty = 5.1;
      elapsed_days = 2;
      scheduled_days = 2;
      reps = 7;
      lapses = 1;
      state = Flashcards.Review;
      last_repeat = now - 172800000;
      last_rating = Some Flashcards.Good;
    }
  in
  let decoded =
    Flashcards.card_of_values (now - 864000000) (Some original.due)
      (Some (Flashcards.state_value original))
  in
  check_eq ~msg:"LG flashcard state codec should round-trip" decoded original;
  check_eq ~msg:"missing FSRS properties should fall back to a new card"
    (Flashcards.card_of_values 42 None None)
    (Flashcards.new_card 42)

let edn_codec_is_lg_owned () =
  match Edn.decode "{:block/tags #{:logseq.class/Task}}" with
  | Ok value ->
    check_eq ~msg:"LG EDN codec should round-trip a Logseq property map"
      (contains ":block/tags" (Edn.encode value))
      true
  | Error message -> fail message

let datascript_value_ref_conversion_is_lg_owned () =
  check_eq ~msg:"LG should recognize built-in Logseq ref attrs"
    (Datascript_value.built_in_ref_attr "block/page")
    true;
  check_eq ~msg:"LG should reject scalar attrs as built-in refs"
    (Datascript_value.built_in_ref_attr "block/title")
    false

let ref_text_converts_between_editor_and_storage_forms () =
  let page_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8" in
  let tag_uuid = "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec9" in
  let title_for_uuid uuid =
    if uuid = page_uuid then Some "Roadmap"
    else if uuid = tag_uuid then Some "favorite book"
    else None
  in
  let resolve_ref title =
    if title = "Roadmap" then Some page_uuid else None
  in
  let resolve_tag title =
    if String.lowercase_ascii title = "project" then Some tag_uuid
    else if title = "favorite book" then Some tag_uuid
    else None
  in
  check_eq ~msg:"canonical UUIDs should be detected"
    (Ref_text.is_uuid page_uuid)
    true;
  check_eq ~msg:"short values should not be UUIDs"
    (Ref_text.is_uuid "018f7850-c6aa")
    false;
  check_eq ~msg:"single-token tags can render as hashtags"
    (Ref_text.plain_tag_label "Project")
    true;
  check_eq ~msg:"multi-word tags should keep bracket syntax"
    (Ref_text.plain_tag_label "favorite book")
    false;
  check_eq ~msg:"tab-separated tags should keep bracket syntax"
    (Ref_text.plain_tag_label "Pro\tject")
    false;
  check_eq ~msg:"stored uuid refs should render with known labels"
    (Ref_text.to_text title_for_uuid title_for_uuid
       ("Ship [[" ^ page_uuid ^ "]] with #[[" ^ tag_uuid
      ^ "]] and #[[missing]]"))
    "Ship [[Roadmap]] with #[[favorite book]] and #[[missing]]";
  check_eq ~msg:"editor refs should resolve back to stored UUID refs"
    (Ref_text.to_ids resolve_ref resolve_tag
       "Ship [[Roadmap]] as #project and #[[favorite book]].")
    ("Ship [[" ^ page_uuid ^ "]] as #[[" ^ tag_uuid ^ "]] and #[[" ^ tag_uuid
   ^ "]].");
  check_eq ~msg:"hashtags can start after tabs"
    (Ref_text.to_ids resolve_ref resolve_tag "todo\t#project")
    ("todo\t#[[" ^ tag_uuid ^ "]]")

let fractional_order_generates_logseq_compatible_keys () =
  check_eq ~msg:"LG fractional ordering should generate midpoint keys"
    (Fractional_order.between (Some "a0") (Some "a1"))
    (Ok "a0V");
  check_eq ~msg:"LG fractional ordering should generate batch keys"
    (Fractional_order.n_between (Some "a0") (Some "a1") 3)
    (Ok [ "a0G"; "a0V"; "a0l" ]);
  check_eq ~msg:"LG fractional ordering should preserve integer width growth"
    (Fractional_order.increment "az")
    (Ok (Some "b00"));
  check_eq ~msg:"LG fractional ordering should reject reversed bounds"
    (Fractional_order.between (Some "a1") (Some "a0"))
    (Error "invalid order bounds")

let empty_outliner_rows_use_the_main_untitled_accessibility_title () =
  let row =
    journal_outline_row "empty" "journal" "" "Aug 28th, 2026" 20260828 0
  in
  check_eq ~msg:"empty blocks retain main's editable Untitled accessibility label"
    (View_base.outliner_row_action_label (Model.initial ()) row)
    "Edit block Untitled block"

let synced_header_control_uses_the_main_accessibility_label () =
  let current = { (Model.initial ()) with Model.sync_state = SyncedState } in
  check_eq ~msg:"the compact header control matches main's spoken status"
    (View_base.sync_indicator_label current)
    "Synced";
  check_eq ~msg:"the detailed status sheet keeps its descriptive summary"
    (View_base.sync_label current)
    "Up to date"

let sync_indicator_prioritizes_connectivity_before_pending_work () =
  let offline_pending =
    {
      (Model.initial ()) with
      Model.sync_state = OfflineState;
      has_pending_semantic_operations = true;
    }
  in
  let connected_pending =
    {
      (Model.initial ()) with
      Model.sync_state = SyncingState;
      has_pending_semantic_operations = true;
    }
  in
  check_eq ~msg:"the status sheet agrees with the disconnected indicator"
    (View_base.sync_label offline_pending)
    "Offline";
  check_eq ~msg:"pending work does not hide an offline connection"
    (View_base.sync_indicator_label offline_pending)
    "Not connected";
  check_eq ~msg:"offline status uses main's opaque red indicator"
    (View_base.sync_indicator_foreground offline_pending)
    "error-foreground";
  check_eq ~msg:"offline pending work remains addressable as disconnected"
    (View_base.sync_accessibility_identifier offline_pending)
    "sync.disconnected";
  check_eq ~msg:"connected pending work keeps the syncing state"
    (View_base.sync_indicator_label connected_pending)
    "Syncing";
  check_eq ~msg:"connected pending work uses an opaque warning foreground"
    (View_base.sync_indicator_foreground connected_pending)
    "warning-foreground";
  check_eq ~msg:"editing offline does not invent a live sync connection"
    (View_base.sync_indicator_label
       (Model.update offline_pending
          (Model.ChangeOutlinerText ("offline-block", "Draft", 5))))
    "Not connected"

let settings_navigation_tabs_and_diagnostics_are_lg_owned () =
  let initial =
    Model.update (Model.initial ())
      (Model.ApplySettingsSnapshot
         (settings [ "journals"; "flashcards"; "graphs" ]))
  in
  let menu = Model.update initial Model.OpenConnectionMenu in
  let opened = Model.update menu Model.OpenSettings in
  let tabs = Model.update opened Model.OpenSettingsTabs in
  let hidden = Model.update tabs (Model.ToggleSidebarTab "flashcards") in
  let logs =
    Model.update (Model.update hidden Model.BackSettings)
      Model.OpenRuntimeLog
  in
  let filtered = Model.update logs Model.ToggleRuntimeLogErrors in
  let refreshed = filtered in
  check ~msg:"the connection menu is model-owned" menu.connection_menu_open;
  check ~msg:"settings presentation is model-owned" opened.settings_open;
  check ~msg:"opening settings dismisses its source menu"
    (not opened.connection_menu_open);
  check ~msg:"tabs navigation is model-owned" tabs.settings_tabs_open;
  check_eq ~msg:"optional sidebar tabs can be hidden" hidden.sidebar_tabs
    [ "journals"; "graphs" ];
  check ~msg:"runtime diagnostics are model-owned" logs.runtime_log_open;
  check ~msg:"log filtering is model-owned" filtered.runtime_log_errors_only;
  check_eq
    ~msg:"opening diagnostics loads records before later filter changes"
    refreshed.pending_effects
    [
      Model.SaveSettingsEffect (1, Model.current_settings hidden);
      Model.RefreshRuntimeLogEffect (2, "ui", false, false);
      Model.RefreshRuntimeLogEffect (3, "ui", true, false);
    ]

let settings_preferences_persist_without_dismissing_the_sheet () =
  let opened =
    Model.update
      (Model.update (Model.initial ())
         (Model.ApplySettingsSnapshot
            (settings [ "journals"; "flashcards"; "graphs" ])))
      Model.OpenSettings
  in
  let themed = Model.update opened (Model.ChangeAppearance "dark") in
  let theme_saved =
    Model.update
      (Model.update themed (Model.DequeueEffect 1))
      (Model.ResolveEffect (1, true, ""))
  in
  let language_opened =
    Model.update theme_saved Model.OpenSettingsLanguageMenu
  in
  let localized =
    Model.update language_opened (Model.ChooseSettingsLanguage "zh-CN")
  in
  let language_saved =
    Model.update
      (Model.update localized (Model.DequeueEffect 2))
      (Model.ResolveEffect (2, true, ""))
  in
  let spell_check_disabled =
    Model.update language_saved (Model.ToggleSpellCheck false)
  in
  let spell_check_saved =
    Model.update
      (Model.update spell_check_disabled (Model.DequeueEffect 3))
      (Model.ResolveEffect (3, true, ""))
  in
  let auto_correction_disabled =
    Model.update spell_check_saved (Model.ToggleAutoCorrection false)
  in
  check_eq ~msg:"theme changes persist immediately like main's AppStorage picker"
    themed.pending_effects
    [ Model.SaveSettingsEffect (1, Model.current_settings themed) ];
  check ~msg:"persisting a preference does not dismiss settings"
    themed.settings_open;
  check_eq
    ~msg:"language changes persist immediately like main's AppStorage picker"
    localized.pending_effects
    [ Model.SaveSettingsEffect (2, Model.current_settings localized) ];
  check ~msg:"language persistence keeps settings visible"
    localized.settings_open;
  check_eq ~msg:"spell check changes persist immediately"
    spell_check_disabled.pending_effects
    [
      Model.SaveSettingsEffect (3, Model.current_settings spell_check_disabled);
    ];
  check_eq ~msg:"auto-correction changes persist immediately"
    auto_correction_disabled.pending_effects
    [
      Model.SaveSettingsEffect
        (4, Model.current_settings auto_correction_disabled);
    ]

let settings_reject_invalid_connections_and_preserve_required_tabs () =
  let opened =
    {
      (Model.initial ()) with
      Model.settings_open = true;
      base_url_draft = "not a server";
    }
  in
  let invalid = Model.update opened Model.ApplySettings in
  let required_toggled =
    Model.update opened (Model.ToggleSidebarTab "journals")
  in
  let required_moved =
    Model.update opened (Model.MoveSidebarTab ("journals", 2))
  in
  check_eq ~msg:"invalid connection URLs do not leave LG"
    invalid.pending_effects [];
  check ~msg:"invalid connection URLs keep settings open for correction"
    invalid.settings_open;
  check ~msg:"HTTPS URLs require a host"
    (not (Model.valid_base_url_ "https:///missing-host"));
  check ~msg:"HTTP URLs cannot substitute a query for the host"
    (not (Model.valid_base_url_ "http://?query-only"));
  check ~msg:"connection hosts cannot contain whitespace"
    (not (Model.valid_base_url_ "https://bad host.example"));
  check ~msg:"local development servers remain valid after trimming"
    (Model.valid_base_url_ " http://127.0.0.1:8787/path ");
  check_eq ~msg:"journals cannot be hidden" required_toggled.sidebar_tabs
    [ "journals"; "flashcards"; "graphs" ];
  check_eq ~msg:"journals remains the first required tab"
    required_moved.sidebar_tabs
    [ "journals"; "flashcards"; "graphs" ];
  check_eq ~msg:"required tab no-ops do not persist settings"
    required_toggled.pending_effects [];
  check_eq ~msg:"required tab moves do not persist settings"
    required_moved.pending_effects []

let settings_snapshot_normalizes_sidebar_tabs_at_the_lg_boundary () =
  let defaulted =
    Model.update (Model.initial ())
      (Model.ApplySettingsSnapshot (settings []))
  in
  let sanitized =
    Model.update (Model.initial ())
      (Model.ApplySettingsSnapshot
         (settings [ "graphs"; "graphs"; "unknown"; "flashcards" ]))
  in
  let required =
    Model.update (Model.initial ())
      (Model.ApplySettingsSnapshot (settings [ "journals" ]))
  in
  check_eq ~msg:"missing persisted tabs use the complete default"
    defaulted.sidebar_tabs
    [ "journals"; "flashcards"; "graphs" ];
  check_eq ~msg:"LG discards unknown and duplicate persisted tabs"
    sanitized.sidebar_tabs
    [ "journals"; "graphs"; "flashcards" ];
  check_eq
    ~msg:"LG restores the required graphs tab without re-enabling flashcards"
    required.sidebar_tabs [ "journals"; "graphs" ]

let runtime_log_filters_refresh_and_successful_results_enter_lg_state () =
  let filtered =
    Model.update (Model.initial ()) Model.ToggleRuntimeLogErrors
  in
  let in_flight = Model.update filtered (Model.DequeueEffect 1) in
  let resolved = Model.update in_flight (Model.ResolveEffect (1, true, "")) in
  let expected = [ runtime_record "1" "INFO" "ui" "Started" ] in
  let applied = Model.update resolved (Model.ApplyRuntimeLog expected) in
  check_eq
    ~msg:"changing a log filter refreshes the visible result immediately"
    filtered.pending_effects
    [ Model.RefreshRuntimeLogEffect (1, "ui", true, false) ];
  check_eq ~msg:"typed host log updates enter retained LG state"
    applied.runtime_log_records expected

let graph_effect_success_owns_selection_and_selected_deletion_cleanup () =
  let local = graph "local" "Local" false true in
  let projected =
    Model.update (Model.initial ())
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           graphs = [ local ];
           selected_graph_id = None;
         })
  in
  let known_local =
    Model.update projected (Model.ApplyLocalGraphIds [ "local" ])
  in
  let requested =
    Model.update known_local (Model.RequestOpenGraph "local")
  in
  let opened =
    Model.update
      (Model.update requested (Model.DequeueEffect 1))
      (Model.ResolveEffect (1, true, "ok"))
  in
  let deletion_requested =
    Model.update opened (Model.RequestDeleteGraph "local")
  in
  let deleting =
    Model.update
      (Model.update deletion_requested Model.ConfirmDeleteGraph)
      (Model.DequeueEffect 2)
  in
  let deleted = Model.update deleting (Model.ResolveEffect (2, true, "ok")) in
  check_eq
    ~msg:"opening a graph updates LG selection after platform success"
    opened.selected_graph_id (Some "local");
  check_eq
    ~msg:"opening a graph projects its title without waiting for a refresh"
    opened.selected_graph (Some "Local");
  check ~msg:"opening a graph enters the retained loading state"
    requested.graph_loading;
  check ~msg:"platform completion exits the retained loading state"
    (not opened.graph_loading);
  check_eq ~msg:"deleting the selected local graph clears its identifier"
    deleted.selected_graph_id None;
  check_eq ~msg:"deleting the selected local graph clears its title"
    deleted.selected_graph None;
  check_eq ~msg:"deleting a local graph removes it from local storage state"
    deleted.local_graph_ids []

let graph_refresh_failure_enters_the_picker_error_state () =
  let requested = Model.update (Model.initial ()) Model.RefreshGraphs in
  let in_flight = Model.update requested (Model.DequeueEffect 1) in
  let failed =
    Model.update in_flight
      (Model.ResolveEffect
         (1, false, "graph_discovery_failed\nConnection refused"))
  in
  check_eq
    ~msg:"a failed catalog refresh renders the picker-specific error state"
    failed.sync_state
    (Model.FailedState "graph_discovery_failed\nConnection refused");
  check ~msg:"the picker error does not also render the global effect error"
    (not (View_base.global_effect_error_present_ failed))

let encrypted_graph_unlock_is_owned_by_lg () =
  let encrypted = graph "encrypted" "Encrypted" true true in
  let catalog_projection =
    { (empty_core_projection ()) with graphs = [ encrypted ] }
  in
  let locked_projection =
    {
      (empty_core_projection ()) with
      graphs = [ encrypted ];
      selected_graph_id = Some "encrypted";
      graph_name = Some "Encrypted";
      is_graph_encrypted = true;
      is_graph_unlocked = false;
    }
  in
  let requested =
    Model.update
      (Model.update (Model.initial ())
         (Model.ApplyCoreSnapshot catalog_projection))
      (Model.RequestOpenGraph "encrypted")
  in
  let opened =
    Model.update
      (Model.update
         (Model.update requested (Model.DequeueEffect 1))
         (Model.ApplyCoreSnapshot locked_projection))
      (Model.ResolveEffect (1, true, ""))
  in
  let blank = Model.update opened Model.SubmitGraphPassword in
  let wrong =
    Model.update
      (Model.update opened (Model.ChangeGraphPassword "wrong"))
      Model.SubmitGraphPassword
  in
  let failed =
    Model.update
      (Model.update wrong (Model.DequeueEffect 2))
      (Model.ResolveEffect (2, false, "Wrong password"))
  in
  let correct =
    Model.update
      (Model.update failed (Model.ChangeGraphPassword "correct"))
      Model.SubmitGraphPassword
  in
  let unlocked_projection =
    { locked_projection with Model.is_graph_unlocked = true }
  in
  let succeeded =
    Model.update
      (Model.update
         (Model.update correct (Model.DequeueEffect 3))
         (Model.ApplyCoreSnapshot unlocked_projection))
      (Model.ResolveEffect (3, true, ""))
  in
  let cancelled =
    Model.update
      (Model.update opened (Model.ChangeGraphPassword "cancel me"))
      Model.CancelGraphUnlock
  in
  check ~msg:"opening a locked encrypted graph presents the password sheet"
    opened.graph_password_open;
  check_eq ~msg:"an empty password never crosses the platform boundary"
    blank.pending_effects [];
  check_eq ~msg:"unlock publishes one typed platform effect"
    wrong.pending_effects
    [ Model.UnlockGraphEffect (2, "wrong") ];
  check ~msg:"an unlock failure keeps the password sheet visible"
    failed.graph_password_open;
  check_eq ~msg:"an unlock failure preserves the entered password"
    failed.graph_password "wrong";
  check_eq ~msg:"an unlock failure remains visible in LG state"
    failed.effect_error (Some "Wrong password");
  check ~msg:"a successful unlock dismisses the password sheet"
    (not succeeded.graph_password_open);
  check_eq ~msg:"a successful unlock clears the password"
    succeeded.graph_password "";
  check ~msg:"cancelling unlock dismisses the password sheet"
    (not cancelled.graph_password_open);
  check_eq ~msg:"cancelling unlock clears the password"
    cancelled.graph_password ""

let encrypted_graph_snapshot_prompts_once_per_selection () =
  let encrypted = graph "encrypted" "Encrypted" true true in
  let catalog =
    { (empty_core_projection ()) with graphs = [ encrypted ] }
  in
  let locked =
    {
      catalog with
      selected_graph_id = Some "encrypted";
      graph_name = Some "Encrypted";
      is_graph_encrypted = true;
      is_graph_unlocked = false;
    }
  in
  let selected =
    Model.update (Model.initial ()) (Model.ApplyCoreSnapshot locked)
  in
  let cancelled = Model.update selected Model.CancelGraphUnlock in
  let refreshed =
    Model.update cancelled (Model.ApplyCoreSnapshot locked)
  in
  let catalogued =
    Model.update refreshed (Model.ApplyCoreSnapshot catalog)
  in
  let selected_again =
    Model.update catalogued (Model.ApplyCoreSnapshot locked)
  in
  check ~msg:"cold-start restoration prompts for a locked selected graph"
    selected.graph_password_open;
  check ~msg:"refreshing the same graph does not reopen a cancelled prompt"
    (not refreshed.graph_password_open);
  check ~msg:"selecting the locked graph again presents a fresh prompt"
    selected_again.graph_password_open

let encrypted_graph_unlock_renders_the_secure_field_contract () =
  let application = App.create (ios_backend ()) in
  let encrypted = graph "encrypted" "Encrypted" true true in
  let catalog_projection =
    { (empty_core_projection ()) with graphs = [ encrypted ] }
  in
  let locked_projection =
    {
      (empty_core_projection ()) with
      graphs = [ encrypted ];
      selected_graph_id = Some "encrypted";
      graph_name = Some "Encrypted";
      is_graph_encrypted = true;
      is_graph_unlocked = false;
    }
  in
  start application;
  send application (Model.ApplyCoreSnapshot catalog_projection);
  send application (Model.RequestOpenGraph "encrypted");
  send application (Model.DequeueEffect 1);
  send application (Model.ApplyCoreSnapshot locked_projection);
  send application (Model.ResolveEffect (1, true, ""));
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let field =
    descendant_with_identifier renderer root "field.graph-password"
  in
  let unlock =
    descendant_with_identifier renderer root "button.graph-unlock"
  in
  let cancel =
    descendant_with_identifier renderer root "button.graph-unlock.cancel"
  in
  check ~msg:"the unlock sheet renders a secure password field"
    (field <> -1);
  check ~msg:"the unlock sheet renders its confirm action" (unlock <> -1);
  check ~msg:"the unlock sheet renders its cancel action" (cancel <> -1);
  check_eq ~msg:"the secure field preserves the existing placeholder"
    (property_string renderer field Lui_protocol.PlaceholderValue)
    "E2EE password";
  dispatch application (Lui_protocol.TextChanged (field, "secret"));
  flush application;
  check_eq ~msg:"secure-field input is retained by LG"
    (App.model application).graph_password "secret";
  dispatch application (Lui_protocol.Press unlock);
  flush application;
  check_eq ~msg:"the unlock button submits the retained password"
    (App.model application).pending_effects
    [ Model.UnlockGraphEffect (2, "secret") ];
  send application (Model.DequeueEffect 2);
  send application (Model.ResolveEffect (2, false, "Wrong password"));
  flush application;
  let error =
    descendant_with_identifier renderer root "text.graph-unlock-error"
  in
  check ~msg:"an unlock failure stays inside the sheet" (error <> -1);
  check_eq ~msg:"the unlock failure explains why the graph stayed locked"
    (property_string renderer error Lui_protocol.TextValue)
    "Wrong password";
  check_eq
    ~msg:"the password sheet does not duplicate its error globally"
    (descendant_count_with_identifier renderer root "error.banner")
    0

let encrypted_graph_unlock_has_a_stable_native_effect_payload () =
  check_eq ~msg:"the native bridge escapes passwords in a typed unlock effect"
    (Native_bridge.encode_effect
       (Model.UnlockGraphEffect (9, "secret \"phrase\"")))
    "{\"id\":9,\"kind\":\"unlock-graph\",\"text\":\"secret \\\"phrase\\\"\"}"

let graph_database_export_has_a_stable_native_effect_payload () =
  check_eq ~msg:"database export leaves file resolution at the platform boundary"
    (Native_bridge.encode_effect (Model.ExportGraphDatabaseEffect 9))
    "{\"id\":9,\"kind\":\"export-graph-database\",\"text\":\"\"}"

let cancel_outliner_editing_has_a_stable_native_effect_payload () =
  check_eq
    ~msg:"destination changes preserve the typed cancel-editing boundary"
    (Native_bridge.encode_effect (Model.CancelOutlinerEditingEffect 9))
    "{\"id\":9,\"kind\":\"cancel-outliner-editing\",\"text\":\"\"}"

let settings_render_the_main_branch_navigation_contract () =
  let application = App.create (ios_backend ()) in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "local";
         graph_name = Some "Local graph";
       });
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application
    (Model.ApplySettingsSnapshot
       (settings [ "journals"; "flashcards"; "graphs" ]));
  send application Model.OpenConnectionMenu;
  send application Model.OpenSettings;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let settings_sheet =
    descendant_with_identifier renderer root "sheet.settings"
  in
  let settings_screen =
    descendant_with_identifier renderer root "screen.settings"
  in
  check_eq ~msg:"the settings root owns the native sheet title"
    (property_string renderer settings_sheet Lui_protocol.TextValue)
    "Settings";
  check_eq ~msg:"the settings root uses the native grouped form sheet"
    (property_string renderer settings_sheet Lui_protocol.StyleClass)
    "navigation-form";
  check ~msg:"settings retain their baseline screen identifier"
    (settings_screen <> -1);
  check_eq ~msg:"the settings content uses the native form layout"
    (property_string renderer settings_screen Lui_protocol.StyleClass)
    "form";
  let tabs_link =
    descendant_with_identifier renderer root "link.settings.tabs"
  in
  let tabs_selection =
    descendant_with_identifier renderer tabs_link
      "text.settings.tabs.selection"
  in
  check ~msg:"settings expose tabs navigation" (tabs_link <> -1);
  check_eq ~msg:"tabs show the same selected-items summary as main"
    (property_string renderer tabs_selection Lui_protocol.TextValue)
    "Journals · Flashcards · Graphs";
  check_eq ~msg:"tabs keep the selected-items summary on one line like main"
    (property_string renderer tabs_selection Lui_protocol.StyleClass)
    "single-line";
  check ~msg:"settings use the native navigation-form toolbar contract"
    (descendant_with_identifier renderer root "toolbar.settings.actions"
    <> -1);
  check ~msg:"settings expose the native cancellation action"
    (descendant_with_identifier renderer root "button.connection.cancel"
    <> -1);
  List.iter
    (fun identifier ->
       check_eq
         ~msg:"settings group labels use main's readable secondary text color"
         (property_string renderer
            (descendant_with_identifier renderer root identifier)
            Lui_protocol.ForegroundValue)
         "muted-foreground")
    [
      "label.settings.general";
      "label.settings.editor";
      "label.settings.sync-server";
      "label.settings.advanced";
      "label.settings.about";
      "label.settings.community";
    ];
  let export =
    descendant_with_identifier renderer root "button.export-graph-database"
  in
  check ~msg:"settings expose database export for a downloaded graph"
    (export <> -1);
  check_eq ~msg:"settings actions align with ordinary card rows"
    (property_int renderer export Lui_protocol.PaddingValue)
    0;
  dispatch application (Lui_protocol.Press export);
  flush application;
  check_eq ~msg:"database export stays on the typed platform boundary"
    (App.model application).pending_effects
    [ Model.ExportGraphDatabaseEffect 1 ];
  send application Model.OpenSettingsTabs;
  flush application;
  let tabs_sheet =
    descendant_with_identifier renderer root "sheet.settings.tabs"
  in
  let tabs_screen =
    descendant_with_identifier renderer root "screen.settings.tabs"
  in
  let flashcards_row =
    descendant_with_identifier renderer root "row.settings.tab.flashcards"
  in
  let back =
    descendant_with_identifier renderer tabs_sheet "button.connection.cancel"
  in
  let confirmation =
    descendant_with_identifier renderer tabs_sheet "button.connection.apply"
  in
  check_eq ~msg:"opening Tabs retains the original Settings sheet"
    (descendant_with_identifier renderer root "sheet.settings")
    settings_sheet;
  check ~msg:"tabs retain their baseline screen identifier"
    (tabs_screen <> -1);
  check_eq ~msg:"tab controls render as full-width native list rows"
    (node renderer flashcards_row)
    (Some Lui_protocol.ListItem);
  check_eq ~msg:"tabs present their own sheet title"
    (property_string renderer tabs_sheet Lui_protocol.TextValue)
    "Tabs";
  check_eq ~msg:"tabs use the native list surface"
    (property_string renderer tabs_sheet Lui_protocol.StyleClass)
    "navigation-list";
  check_eq ~msg:"tabs expose a settings back action"
    (property_string renderer back Lui_protocol.TextValue)
    "Settings";
  check_eq ~msg:"tabs do not retain the root Apply action" confirmation (-1);
  check ~msg:"configurable tabs retain their stable identifiers"
    (descendant_with_identifier renderer root "toggle.settings.tab.flashcards"
    <> -1);
  send application Model.BackSettings;
  send application Model.OpenRuntimeLog;
  send application
    (Model.ApplyRuntimeLog [ runtime_record "1" "INFO" "ui" "Started" ]);
  flush application;
  check ~msg:"runtime log retains its baseline screen identifier"
    (descendant_with_identifier renderer root "screen.runtime-log" <> -1);
  check ~msg:"runtime diagnostics retain their actions"
    (descendant_with_identifier renderer root "button.log-copy" <> -1)

let kotlin_settings_sheet_uses_one_bounded_scroll_layout () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "local";
         graph_name = Some "Local graph";
       });
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.OpenConnectionMenu;
  send application Model.OpenSettings;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let sheet = descendant_with_identifier renderer root "sheet.settings" in
  let layout =
    descendant_with_identifier renderer sheet "layout.settings.sheet"
  in
  check_eq ~msg:"Kotlin bounds the Material bottom sheet"
    (property_int renderer sheet Lui_protocol.HeightValue)
    640;
  check_eq ~msg:"Kotlin gives the backend one composed sheet child"
    (List.length (children renderer sheet))
    1;
  check ~msg:"Kotlin owns one vertical settings layout" (layout <> -1);
  if layout <> -1 then begin
    check_eq ~msg:"long Settings content scrolls inside the sheet"
      (descendant_count_with_node_kind renderer layout Lui_protocol.Scroll)
      1;
    check ~msg:"Settings actions remain below the scrollable content"
      (descendant_with_identifier renderer layout "toolbar.settings.actions"
      <> -1)
  end

let kotlin_settings_tabs_open_through_the_rendered_press_handler () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application
    (Model.ApplySettingsSnapshot
       (settings [ "journals"; "flashcards"; "graphs" ]));
  send application Model.OpenSettings;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let tabs_link =
    descendant_with_identifier renderer root "link.settings.tabs"
  in
  check ~msg:"Kotlin renders the Settings tabs navigation row"
    (tabs_link <> -1);
  dispatch application (Lui_protocol.Press tabs_link);
  flush application;
  let updated_root = main_root renderer application in
  let sheet =
    descendant_with_identifier renderer updated_root "sheet.settings"
  in
  let layout =
    descendant_with_identifier renderer updated_root
      "layout.settings.tabs-sheet"
  in
  let tabs_screen =
    descendant_with_identifier renderer updated_root "screen.settings.tabs"
  in
  let actions =
    descendant_with_identifier renderer updated_root
      "toolbar.settings.actions"
  in
  let back =
    descendant_with_identifier renderer updated_root
      "button.connection.cancel"
  in
  let flashcards_toggle =
    descendant_with_identifier renderer updated_root
      "toggle.settings.tab.flashcards"
  in
  check ~msg:"pressing the rendered row opens the Tabs screen"
    (descendant_with_identifier renderer updated_root "screen.settings.tabs"
    <> -1);
  check_eq ~msg:"the Tabs screen replaces the Settings main screen"
    (descendant_with_identifier renderer updated_root "screen.settings")
    (-1);
  check_eq ~msg:"Kotlin gives the Tabs sheet one bounded child"
    (List.length (children renderer sheet))
    1;
  check ~msg:"Kotlin owns one vertical Tabs layout" (layout <> -1);
  if layout <> -1 then begin
    check_eq ~msg:"Tabs uses one vertical Material layout"
      (node renderer layout)
      (Some Lui_protocol.Column);
    check_eq ~msg:"the tab list and back action occupy separate rows"
      (children renderer layout)
      [ tabs_screen; actions ]
  end;
  check_eq ~msg:"the tab list consumes only the space above the action"
    (property_float renderer tabs_screen Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"the back action uses an anchored Material row"
    (node renderer actions)
    (Some Lui_protocol.Row);
  check_eq ~msg:"the back action fills the available phone width"
    (property_float renderer back Lui_protocol.GrowValue)
    1.0;
  check_eq
    ~msg:
      "tab state stays leading while spare width separates reorder actions"
    (property_float renderer flashcards_toggle Lui_protocol.GrowValue)
    (-1.0)

let kotlin_runtime_log_actions_fit_phone_width () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "local";
         graph_name = Some "Local graph";
       });
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.OpenSettings;
  send application Model.OpenRuntimeLog;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let sheet = descendant_with_identifier renderer root "sheet.settings" in
  let layout =
    descendant_with_identifier renderer root "layout.runtime-log.sheet"
  in
  let screen =
    descendant_with_identifier renderer root "screen.runtime-log"
  in
  let actions =
    descendant_with_identifier renderer root "toolbar.settings.actions"
  in
  let refresh =
    descendant_with_identifier renderer root "button.log-refresh"
  in
  let done_button =
    descendant_with_identifier renderer root "button.connection.apply"
  in
  check_eq ~msg:"Kotlin gives the Runtime log sheet one bounded child"
    (List.length (children renderer sheet))
    1;
  check ~msg:"Kotlin owns one vertical Runtime log layout" (layout <> -1);
  if layout <> -1 then begin
    check_eq ~msg:"Runtime log owns one vertical Material layout"
      (node renderer layout)
      (Some Lui_protocol.Column);
    check_eq ~msg:"the log screen and its action bar occupy separate rows"
      (children renderer layout)
      [ screen; actions ]
  end;
  check_eq ~msg:"the log screen consumes only the space above the actions"
    (property_float renderer screen Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"Runtime log actions use an anchored Material row"
    (node renderer actions)
    (Some Lui_protocol.Row);
  check_eq ~msg:"Refresh is the secondary Runtime log action"
    (property_string renderer refresh Lui_protocol.VariantValue)
    "secondary";
  check_eq ~msg:"Done is the primary Runtime log action"
    (property_string renderer done_button Lui_protocol.VariantValue)
    "primary";
  check_eq ~msg:"Refresh shares the phone width"
    (property_float renderer refresh Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"Done shares the phone width"
    (property_float renderer done_button Lui_protocol.GrowValue)
    1.0;
  check ~msg:"Kotlin groups the first two log actions into a bounded row"
    (descendant_with_identifier renderer root "toolbar.log-filters.primary"
    <> -1);
  check ~msg:"Kotlin groups the remaining log actions into a bounded row"
    (descendant_with_identifier renderer root
       "toolbar.log-filters.secondary"
    <> -1)

let kotlin_settings_use_full_width_material_controls () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "local";
         graph_name = Some "Local graph";
       });
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.OpenSettings;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let picker =
    descendant_with_identifier renderer root "picker.settings.language"
  in
  let appearance_control =
    descendant_with_identifier renderer root
      "layout.settings.appearance-control"
  in
  let appearance_picker =
    descendant_with_identifier renderer root "picker.settings.appearance"
  in
  let language_control =
    descendant_with_identifier renderer root
      "layout.settings.language-control"
  in
  let general_card =
    descendant_with_identifier renderer root "layout.settings.general-card"
  in
  let actions =
    descendant_with_identifier renderer root "toolbar.settings.actions"
  in
  let cancel =
    descendant_with_identifier renderer root "button.connection.cancel"
  in
  let apply =
    descendant_with_identifier renderer root "button.connection.apply"
  in
  let tabs_copy =
    descendant_with_identifier renderer root "layout.settings.tabs-copy"
  in
  let tabs_selection =
    descendant_with_identifier renderer root "text.settings.tabs.selection"
  in
  let tabs_icon =
    descendant_with_identifier renderer root "icon.settings.tabs"
  in
  let spell_check =
    descendant_with_identifier renderer root "switch.settings.spell-check"
  in
  let auto_correction =
    descendant_with_identifier renderer root
      "switch.settings.auto-correction"
  in
  let export =
    descendant_with_identifier renderer root "button.export-graph-database"
  in
  let runtime_log =
    descendant_with_identifier renderer root "button.runtime-log"
  in
  let report_bug =
    descendant_with_identifier renderer root
      "link.settings.community.report-bug"
  in
  let sign_out =
    descendant_with_identifier renderer root "button.sign-out"
  in
  check_eq ~msg:"Kotlin uses one bounded Material select control"
    (node renderer picker)
    (Some Lui_protocol.Select);
  check_eq ~msg:"Kotlin exposes the Material Theme select directly"
    (node renderer appearance_picker)
    (Some Lui_protocol.Select);
  check_eq ~msg:"the Theme select is not pinned to a phone-specific width"
    (property_int renderer appearance_control Lui_protocol.WidthValue)
    (-1);
  check_eq ~msg:"the Language select is not pinned to a phone-specific width"
    (property_int renderer language_control Lui_protocol.WidthValue)
    (-1);
  check_eq ~msg:"Material settings controls fill the available card width"
    (property_string renderer general_card Lui_protocol.CrossAlignment)
    "stretch";
  check_eq
    ~msg:
      "Material settings use a tonal container instead of a white form \
       rectangle"
    (property_string renderer general_card Lui_protocol.BackgroundValue)
    "surface-container-low";
  check_eq
    ~msg:
      "Material settings cards and the action bar share one tonal hierarchy"
    (descendant_count_with_property_string renderer root
       Lui_protocol.BackgroundValue "surface-container-low")
    8;
  check_eq ~msg:"the appearance select keeps a persistent Material field label"
    (property_string renderer appearance_picker
       Lui_protocol.AccessibilityLabel)
    "Theme";
  check_eq ~msg:"the language select keeps a persistent Material field label"
    (property_string renderer picker Lui_protocol.AccessibilityLabel)
    "Language";
  check_eq ~msg:"the tabs label and summary own the flexible row width"
    (property_float renderer tabs_copy Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"the tabs summary is secondary supporting text"
    (property_string renderer tabs_selection Lui_protocol.StyleClass)
    "footnote";
  check_eq ~msg:"the tabs summary uses readable Material supporting text"
    (property_string renderer tabs_selection Lui_protocol.ForegroundValue)
    "muted-foreground";
  check_eq ~msg:"Tabs uses a Material navigation affordance"
    (property_string renderer tabs_icon Lui_protocol.IconName)
    "app:chevron-right";
  check_eq ~msg:"spell check uses a native Material switch row"
    (node renderer spell_check)
    (Some Lui_protocol.SwitchControl);
  check_eq ~msg:"auto-correction uses a native Material switch row"
    (node renderer auto_correction)
    (Some Lui_protocol.SwitchControl);
  check_eq ~msg:"graph export uses a recognizable Material action icon"
    (property_string renderer export Lui_protocol.InlineIconName)
    "app:download";
  check_eq ~msg:"runtime diagnostics use a recognizable Material icon"
    (property_string renderer runtime_log Lui_protocol.InlineIconName)
    "app:terminal";
  check_eq ~msg:"community links disclose that they leave the app"
    (property_string renderer report_bug Lui_protocol.InlineIconName)
    "app:open-external";
  check_eq ~msg:"sign out uses the Android logout icon"
    (property_string renderer sign_out Lui_protocol.InlineIconName)
    "app:sign-out";
  check_eq ~msg:"settings actions use an anchored Material action row"
    (node renderer actions)
    (Some Lui_protocol.Row);
  check_eq ~msg:"settings actions keep Material button separation"
    (property_int renderer actions Lui_protocol.Gap)
    12;
  check_eq ~msg:"Cancel is the quiet tonal action"
    (property_string renderer cancel Lui_protocol.VariantValue)
    "secondary";
  check_eq ~msg:"Apply is the unmistakable primary action"
    (property_string renderer apply Lui_protocol.VariantValue)
    "primary";
  check_eq ~msg:"Cancel and Apply share the available phone width"
    (property_float renderer cancel Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"Cancel and Apply share the available phone width"
    (property_float renderer apply Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"Kotlin does not lay every language out in one row"
    (descendant_count_with_node_kind renderer picker Lui_protocol.RadioGroup)
    0;
  send application Model.OpenSettingsLanguageMenu;
  flush application;
  let root = main_root renderer application in
  let system =
    descendant_with_identifier renderer root "button.settings.language.system"
  in
  let menu =
    parent_with_child_identifier renderer root
      "button.settings.language.system"
  in
  check_eq ~msg:"opening the language selector presents a Material menu"
    (node renderer menu)
    (Some Lui_protocol.DropdownMenu);
  check ~msg:"the Material menu retains every shared language choice"
    (descendant_count_with_property_string renderer menu
       Lui_protocol.TextValue "简体中文"
    = 1);
  check ~msg:"each Material language choice exposes a stable automation target"
    (system <> -1);
  if system <> -1 then begin
    dispatch application (Lui_protocol.Press system);
    flush application;
    check_eq ~msg:"the System menu item selects its own language id"
      (App.model application).language "system"
  end

let settings_tabs_match_main_visibility_and_movement_boundaries () =
  let application = App.create (ios_backend ()) in
  start application;
  send application
    (Model.ApplySettingsSnapshot
       (settings [ "journals"; "flashcards"; "graphs" ]));
  send application Model.OpenSettings;
  send application Model.OpenSettingsTabs;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = application_shell_root renderer application in
  check_eq ~msg:"the drawer leaves the same visible main edge as main"
    (property_int renderer root Lui_protocol.WidthValue)
    360;
  check_eq ~msg:"journals remains visibly required"
    (descendant_enabled renderer root "toggle.settings.tab.journals")
    (Some false);
  check_eq ~msg:"journals does not render movement controls"
    (descendant_with_identifier renderer root
       "button.settings.tab.journals.up")
    (-1);
  check_eq ~msg:"flashcards remains configurable"
    (descendant_enabled renderer root "toggle.settings.tab.flashcards")
    (Some true);
  check_eq ~msg:"the first configurable tab cannot move above journals"
    (descendant_enabled renderer root "button.settings.tab.flashcards.up")
    (Some false);
  check_eq ~msg:"the first configurable tab can move down"
    (descendant_enabled renderer root "button.settings.tab.flashcards.down")
    (Some true);
  check_eq ~msg:"graphs remains visibly required"
    (descendant_enabled renderer root "toggle.settings.tab.graphs")
    (Some false);
  check_eq ~msg:"the last required tab can move within visible tabs"
    (descendant_enabled renderer root "button.settings.tab.graphs.up")
    (Some true);
  check_eq ~msg:"the last tab cannot move beyond the visible list"
    (descendant_enabled renderer root "button.settings.tab.graphs.down")
    (Some false);
  dispatch application
    (Lui_protocol.Press
       (descendant_with_identifier renderer root
          "toggle.settings.tab.flashcards"));
  flush application;
  let updated_root = Lui_app.root_node application in
  check_eq ~msg:"hidden tabs do not retain movement controls"
    (descendant_with_identifier renderer updated_root
       "button.settings.tab.flashcards.up")
    (-1);
  check_eq ~msg:"hidden tabs do not expose invalid downward movement"
    (descendant_with_identifier renderer updated_root
       "button.settings.tab.flashcards.down")
    (-1);
  check_eq ~msg:"a lone configurable position cannot move up"
    (descendant_enabled renderer updated_root "button.settings.tab.graphs.up")
    (Some false);
  check_eq ~msg:"a lone configurable position cannot move down"
    (descendant_enabled renderer updated_root
       "button.settings.tab.graphs.down")
    (Some false)

let android_disclosure_and_selection_icons_use_material_semantics () =
  let current =
    {
      (Model.initial ()) with
      Model.sidebar_tabs = [ "journals"; "graphs" ];
    }
  in
  check_eq ~msg:"collapsed rows use a Material forward disclosure icon"
    (View_base.outliner_collapse_icon_name true)
    "app:chevron-right";
  check_eq ~msg:"expanded rows use a Material downward disclosure icon"
    (View_base.outliner_collapse_icon_name false)
    "app:chevron-down";
  check_eq ~msg:"visible settings tabs use the selected Material state"
    (View_base.tab_selection_icon_name current "journals")
    "app:selected";
  check_eq ~msg:"hidden settings tabs use the unselected Material state"
    (View_base.tab_selection_icon_name current "flashcards")
    "app:unselected"

let settings_tabs_render_saved_order_and_separate_available_tabs () =
  let application = App.create (ios_backend ()) in
  start application;
  send application
    (Model.ApplySettingsSnapshot
       (settings [ "journals"; "graphs"; "flashcards" ]));
  send application Model.OpenSettings;
  send application Model.OpenSettingsTabs;
  flush application;
  let renderer = Lui_app.runtime application in
  let screen =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "screen.settings.tabs"
  in
  let journals =
    child_index_with_identifier renderer screen "row.settings.tab.journals"
  in
  let graphs =
    child_index_with_identifier renderer screen "row.settings.tab.graphs"
  in
  let flashcards =
    child_index_with_identifier renderer screen "row.settings.tab.flashcards"
  in
  check ~msg:"visible tab rows follow the persisted order"
    (journals < graphs && graphs < flashcards);
  check_eq ~msg:"the available section is absent while every tab is visible"
    (child_index_with_identifier renderer screen
       "text.settings.tabs.available")
    (-1);
  dispatch application
    (Lui_protocol.Press
       (descendant_with_identifier renderer screen
          "toggle.settings.tab.flashcards"));
  flush application;
  let available =
    child_index_with_identifier renderer screen "text.settings.tabs.available"
  in
  let available_flashcards =
    child_index_with_identifier renderer screen "row.settings.tab.flashcards"
  in
  check ~msg:"hiding a configurable tab creates the available section"
    (available <> -1);
  check ~msg:"hidden tabs render under the available section"
    (available < available_flashcards)

let settings_language_picker_exposes_and_validates_all_main_choices () =
  let application = App.create (ios_backend ()) in
  start application;
  send application Model.OpenSettings;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let picker =
    descendant_with_identifier renderer root "picker.settings.language"
  in
  check_eq ~msg:"language choices use the native Picker contract"
    (node renderer picker)
    (Some Lui_protocol.RadioGroup);
  check_eq ~msg:"the native Picker keeps main's adaptive menu presentation"
    (property_string renderer picker Lui_protocol.StyleClass)
    "menu";
  let simplified_chinese =
    descendant_with_identifier renderer picker "button.settings.language.zh-CN"
  in
  let system =
    descendant_with_identifier renderer picker "button.settings.language.system"
  in
  let arabic =
    descendant_with_identifier renderer picker "button.settings.language.ar"
  in
  check ~msg:"the picker retains the Simplified Chinese choice"
    (simplified_chinese <> -1);
  check ~msg:"the native picker renders the selected language"
    (property_bool renderer system Lui_protocol.Checked);
  check ~msg:"the picker retains the final main-branch language choice"
    (arabic <> -1);
  dispatch application (Lui_protocol.Change simplified_chinese);
  flush application;
  check_eq ~msg:"selecting a language updates LG settings state"
    (App.model application).language "zh-CN";
  check ~msg:"selecting a language dismisses its menu"
    (not (App.model application).settings_language_menu_open);
  send application Model.OpenSettingsLanguageMenu;
  send application (Model.ChooseSettingsLanguage "unknown");
  flush application;
  check_eq ~msg:"unknown language identifiers cannot enter LG state"
    (App.model application).language "zh-CN";
  check ~msg:"rejecting an unknown language still dismisses the menu"
    (not (App.model application).settings_language_menu_open)

let settings_community_links_use_a_typed_platform_boundary () =
  let application = App.create (ios_backend ()) in
  start application;
  send application Model.OpenSettings;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let report_bug =
    descendant_with_identifier renderer root
      "link.settings.community.report-bug"
  in
  let github =
    descendant_with_identifier renderer root "link.settings.community.github"
  in
  check ~msg:"settings retain the issue tracker link" (report_bug <> -1);
  check ~msg:"settings retain the GitHub community link" (github <> -1);
  dispatch application (Lui_protocol.Press github);
  flush application;
  check_eq ~msg:"community navigation stays on the typed platform boundary"
    (App.model application).pending_effects
    [ Model.OpenExternalURLEffect (1, "https://github.com/logseq/logseq") ];
  check_eq ~msg:"the native bridge preserves the trusted community URL"
    (Native_bridge.encode_effect
       (Model.OpenExternalURLEffect (1, "https://github.com/logseq/logseq")))
    "{\"id\":1,\"kind\":\"open-external-url\",\"text\":\"https://github.com/logseq/logseq\"}"

let authentication_entry_is_lg_owned_and_idempotent () =
  let signed_out =
    Model.update (Model.initial ())
      (Model.ApplyAuthentication ("signedOut", None))
  in
  let signing_in = Model.update signed_out Model.SignIn in
  let duplicate = Model.update signing_in Model.SignIn in
  let in_flight = Model.update signing_in (Model.DequeueEffect 1) in
  let premature_host_failure =
    Model.update in_flight
      (Model.ApplyAuthentication
         ("signedOut", Some "Authorization was cancelled"))
  in
  let failed =
    Model.update in_flight
      (Model.ResolveEffect (1, false, "Hosted sign-in was cancelled"))
  in
  let signed_in =
    Model.update failed (Model.ApplyAuthentication ("signedIn", None))
  in
  let invalid =
    Model.update signed_in
      (Model.ApplyAuthentication ("unexpected", Some "bad"))
  in
  check_eq ~msg:"the platform can publish signed-out authentication"
    signed_out.authentication_state "signedOut";
  check_eq ~msg:"sign-in crosses one typed platform boundary"
    signing_in.pending_effects
    [ Model.SignInEffect 1 ];
  check_eq ~msg:"LG disables repeated sign-in while Hosted UI is active"
    signing_in.authentication_state "signingIn";
  check_eq ~msg:"repeated sign-in requests are ignored" duplicate signing_in;
  check_eq
    ~msg:"host callbacks cannot re-enable sign-in before effect resolution"
    premature_host_failure.authentication_state "signingIn";
  check_eq ~msg:"failed Hosted UI returns to the signed-out screen"
    failed.authentication_state "signedOut";
  check_eq ~msg:"authentication failures remain visible in LG state"
    failed.authentication_error
    (Some "Hosted sign-in was cancelled");
  check_eq ~msg:"successful authentication restores the application"
    signed_in.authentication_state "signedIn";
  check_eq ~msg:"unknown platform authentication states are rejected" invalid
    signed_in;
  check_eq ~msg:"Hosted UI uses a stable typed effect payload"
    (Native_bridge.encode_effect (Model.SignInEffect 9))
    "{\"id\":9,\"kind\":\"sign-in\",\"text\":\"\"}"

let authentication_screen_renders_from_lg_state () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.ApplyAuthentication ("signedOut", None));
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let screen =
    descendant_with_identifier renderer root "screen.authentication"
  in
  let sign_in =
    descendant_with_identifier renderer root "button.hosted-sign-in"
  in
  check ~msg:"signed-out authentication renders the LG entry screen"
    (screen <> -1);
  check_eq
    ~msg:
      "authentication replaces the graph picker instead of sharing the root"
    (descendant_with_identifier renderer root "screen.graph-picker")
    (-1);
  check_eq ~msg:"authentication replaces loaded journal content"
    (descendant_with_identifier renderer root "journals.graph-loaded")
    (-1);
  check_eq ~msg:"authentication replaces the journal loading surface"
    (descendant_with_identifier renderer root "journals.loading")
    (-1);
  check_eq ~msg:"authentication hides capture controls"
    (descendant_with_identifier renderer root "button.composer.expand")
    (-1);
  check_eq ~msg:"authentication hides search controls"
    (descendant_with_identifier renderer root "button.search")
    (-1);
  check_eq ~msg:"authentication hides the signed-in navigation header"
    (descendant_with_identifier renderer root "button.sidebar")
    (-1);
  check_eq ~msg:"authentication fills the available root height"
    (property_float renderer screen Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"authentication owns the full vertical container"
    (property_string renderer screen
       Lui_protocol.ContainerRelativeFrameValue)
    "vertical";
  check_eq ~msg:"authentication content is vertically centered"
    (property_string renderer screen Lui_protocol.MainAlignment)
    "center";
  check_eq ~msg:"authentication content is horizontally centered"
    (property_string renderer screen Lui_protocol.CrossAlignment)
    "center";
  check_eq ~msg:"authentication inherits the app theme background"
    (property_string renderer screen Lui_protocol.BackgroundValue)
    "<missing>";
  check_eq ~msg:"authentication uses main's prominent sign-in action"
    (property_string renderer sign_in Lui_protocol.VariantValue)
    "primary";
  check_eq ~msg:"the signed-out action is enabled"
    (descendant_enabled renderer root "button.hosted-sign-in")
    (Some true);
  dispatch application (Lui_protocol.Press sign_in);
  flush application;
  check_eq ~msg:"the button disables while Hosted UI is active"
    (descendant_enabled renderer root "button.hosted-sign-in")
    (Some false);
  send application (Model.DequeueEffect 1);
  send application
    (Model.ResolveEffect (1, false, "Authorization was cancelled"));
  flush application;
  let error =
    descendant_with_identifier renderer root "text.authentication-error"
  in
  check_eq ~msg:"authentication errors render inside the LG screen"
    (property_string renderer error Lui_protocol.TextValue)
    "Authorization was cancelled";
  send application (Model.ApplyAuthentication ("signedIn", None));
  flush application;
  check_eq ~msg:"signed-in authentication dismisses the LG entry screen"
    (descendant_with_identifier renderer root "screen.authentication")
    (-1)

let authentication_screen_uses_the_product_name_on_every_host () =
  List.iter
    (fun backend ->
       let application = App.create backend in
       start application;
       send application (Model.ApplyAuthentication ("signedOut", None));
       flush application;
       let renderer = Lui_app.runtime application in
       let root = Lui_app.root_node application in
       check_eq ~msg:"the signed-out surface uses the installed product name"
         (descendant_count_with_property_string renderer root
            Lui_protocol.TextValue "Logseq")
         1)
    [ ios_backend (); kotlin_backend () ]

let outliner_editor_extension_contract_is_pinned () =
  check_eq ~msg:"the native editor registry must match the LG wire schema"
    (Lui_extension.fingerprint (View.outliner_editor_schema ()))
    "lui-extension-v1|15:outliner-editor|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:18:caret-utf16-offset:int:required:none,5:title:string:required:none,8:block-id:string:required:none|events:11:text-change[18:caret-utf16-offset:int:required,5:title:string:required],12:caret-change[18:caret-utf16-offset:int:required],6:return[18:caret-utf16-offset:int:required,5:title:string:required],9:backspace[16:selection-length:int:required,5:title:string:required]"

let outliner_block_content_extension_contract_is_pinned () =
  check_eq ~msg:"the rich block renderer must match the LG wire schema"
    (Lui_extension.fingerprint (View.outliner_block_content_schema ()))
    "lui-extension-v1|22:outliner-block-content|profiles:android/kotlin,ios/swiftui|standard-children:0|children:|properties:10:asset-type:string:required:none,10:local-path:string:required:none,11:markup-json:string:required:none,12:is-completed:bool:required:none,18:youtube-target-url:string:required:none,5:title:string:required:none,8:block-id:string:required:none,8:is-asset:bool:required:none|events:10:drag-start[4:uuid:string:required],4:drop[4:uuid:string:required,9:placement:string:required],4:edit[4:uuid:string:required],9:open-node[4:uuid:string:required]"

let native_navigation_stack_extension_contract_is_pinned () =
  let schema =
    Lui_extension.schema (View.extension_registry ())
      "native-navigation-stack"
  in
  let fingerprint =
    match schema with
    | Some current -> Some (Lui_extension.fingerprint current)
    | None -> None
  in
  check_eq
    ~msg:"native navigation must share one pinned LG and Swift wire contract"
    fingerprint
    (Some
       "lui-extension-v1|23:native-navigation-stack|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:10:back-depth:int:required:none,26:composer-dismissal-enabled:bool:required:none,28:bottom-occupies-layout-space:bool:required:none,5:depth:int:required:none,5:title:string:required:none|events:16:dismiss-composer[],4:back[5:count:int:required]")

let native_search_presentation_extension_contract_is_pinned () =
  let schema =
    Lui_extension.schema (View.extension_registry ())
      "native-search-presentation"
  in
  let fingerprint =
    match schema with
    | Some current -> Some (Lui_extension.fingerprint current)
    | None -> None
  in
  check_eq
    ~msg:"search must use a distinct native full-screen navigation contract"
    fingerprint
    (Some
       "lui-extension-v1|26:native-search-presentation|profiles:android/kotlin,ios/swiftui|standard-children:1|children:|properties:5:depth:int:required:none,5:query:string:required:none,5:title:string:required:none,9:presented:bool:required:none|events:13:query-changed[5:query:string:required],4:back[5:count:int:required],7:dismiss[]")

let liquid_glass_remains_an_ios_local_tweak () =
  let registry = View.extension_registry () in
  let schema = Lui_extension.schema registry "liquid-glass" in
  check ~msg:"app-specific appearance does not expand the standard LUI protocol"
    (Lui_extension.is_tweak registry "liquid-glass");
  check_eq ~msg:"the native tweak registry must match the LG wire schema"
    (match schema with
     | Some current -> Some (Lui_extension.tweak_fingerprint current)
     | None -> None)
    (Some
       "lui-tweak-v1|12:liquid-glass|profiles:ios/swiftui|properties:5:shape:string:required:none")

let extension_kind runtime node =
  Hashtbl.find_opt runtime.Lui_runtime.runtime_extension_nodes node

let outliner_drag_selects_once_and_drop_keeps_placement () =
  let unselected = App.create (ios_backend ()) in
  let selected = App.create (ios_backend ()) in
  start unselected;
  send unselected (Model.BeginOutlinerDrag "source");
  flush unselected;
  check_eq ~msg:"dragging an unselected block first selects it through the core"
    (App.model unselected).pending_effects
    [ Model.LongPressOutlinerBlockEffect (1, "source") ];
  start selected;
  send selected
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       None None [] [ "source" ] [] false []);
  flush selected;
  send selected (Model.BeginOutlinerDrag "source");
  flush selected;
  check_eq ~msg:"dragging an already selected block does not toggle selection"
    (App.model selected).pending_effects [];
  send selected (Model.DropOutlinerBlocks ("target", "inside"));
  flush selected;
  check_eq ~msg:"drop placement crosses the typed LG boundary unchanged"
    (App.model selected).pending_effects
    [ Model.DropOutlinerBlocksEffect (1, "target", "inside") ];
  check_eq ~msg:"the native bridge preserves the drop target and placement"
    (Native_bridge.encode_effect
       (Model.DropOutlinerBlocksEffect (9, "target", "after")))
    "{\"id\":9,\"kind\":\"drop-outliner-blocks\",\"text\":\"target\",\"metadata\":\"after\"}"

let initial_shell_renders_the_graph_picker_without_a_selected_graph () =
  let application = App.create (ios_backend ()) in
  let remote = graph "remote" "Remote graph" false true in
  start application;
  flush application;
  let renderer = Lui_app.runtime application in
  let main = main_root renderer application in
  let picker = child_with_identifier renderer main "screen.graph-picker" in
  check_eq ~msg:"the shell starts without an invented graph"
    (App.model application).selected_graph None;
  check ~msg:"an empty launch matches main's graph picker" (picker <> -1);
  check_eq ~msg:"the launch picker bypasses journal navigation chrome"
    (extension_node application "native-navigation-stack")
    (-1);
  check ~msg:"the launch picker can create a graph"
    (child_with_identifier renderer picker "button.graph-add" <> -1);
  send application Model.OpenSidebar;
  flush application;
  let drawer =
    descendant_with_node_kind renderer (Lui_app.root_node application)
      Lui_protocol.Drawer
  in
  check_eq ~msg:"the graph picker keeps sidebar content non-interactive"
    (property_bool renderer drawer Lui_protocol.Enabled)
    false;
  check_eq ~msg:"the graph picker cannot reveal a retained open drawer"
    (property_bool renderer drawer Lui_protocol.Selected)
    false;
  send application Model.CloseSidebar;
  flush application;
  send application
    (Model.ApplyCoreSnapshot
       { (empty_core_projection ()) with graphs = [ remote ] });
  flush application;
  let updated_main = main_root renderer application in
  let updated_picker =
    child_with_identifier renderer updated_main "screen.graph-picker"
  in
  let graph_row =
    descendant_with_identifier renderer updated_picker "graph.remote"
  in
  let graph_scroll =
    descendant_with_node_kind renderer updated_picker Lui_protocol.Scroll
  in
  check ~msg:"catalog updates retain the launch picker" (graph_row <> -1);
  check ~msg:"the graph catalog uses a plain scrolling list"
    (graph_scroll <> -1);
  check_eq ~msg:"a graph row keeps native list-item interaction"
    (node renderer graph_row)
    (Some Lui_protocol.ListItem);
  check_eq ~msg:"graph rows do not add graph-type icons"
    (descendant_count_with_node_kind renderer graph_row Lui_protocol.Icon)
    0;
  check_eq ~msg:"graph rows use a compact horizontal inset"
    (property_int renderer graph_row Lui_protocol.PaddingHorizontal)
    12;
  check_eq ~msg:"graph rows keep a comfortable touch target"
    (property_int renderer graph_row Lui_protocol.MinHeight)
    44;
  check_eq ~msg:"graph rows do not use card backgrounds"
    (property renderer graph_row Lui_protocol.BackgroundValue)
    None;
  dispatch application (Lui_protocol.Press graph_row);
  flush application;
  check_eq ~msg:"a launch graph uses the typed graph lifecycle"
    (App.model application).pending_effects
    [ Model.OpenGraphEffect (1, "remote") ]

let graph_picker_not_ready_status_matches_main_copy () =
  let application = App.create (ios_backend ()) in
  let preparing = graph "preparing" "Preparing graph" false false in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       { (empty_core_projection ()) with graphs = [ preparing ] });
  flush application;
  let renderer = Lui_app.runtime application in
  let picker =
    child_with_identifier renderer (main_root renderer application)
      "screen.graph-picker"
  in
  let status =
    descendant_with_identifier renderer picker "graph.status.preparing"
  in
  check_eq ~msg:"the unavailable graph explanation matches main"
    (property_string renderer status Lui_protocol.TextValue)
    "Graph is not ready for sync."

let graph_picker_matches_main_layout_actions_errors_and_overflow_menu () =
  let application = App.create (ios_backend ()) in
  start application;
  flush application;
  let renderer = Lui_app.runtime application in
  let main = main_root renderer application in
  let picker = child_with_identifier renderer main "screen.graph-picker" in
  let add = child_with_identifier renderer picker "button.graph-add" in
  let refresh =
    child_with_identifier renderer picker "button.graphs.refresh"
  in
  let overflow =
    descendant_with_identifier renderer picker "button.connection"
  in
  check_eq ~msg:"the picker preserves main's vertical spacing"
    (property_int renderer picker Lui_protocol.Gap)
    20;
  check_eq ~msg:"the picker preserves main's page inset"
    (property_int renderer picker Lui_protocol.PaddingValue)
    24;
  check_eq ~msg:"a long graph catalog remains pinned below the safe area"
    (property_string renderer picker Lui_protocol.MainAlignment)
    "start";
  check_eq ~msg:"the picker is constrained to the navigation viewport"
    (property_string renderer picker Lui_protocol.ContainerRelativeFrameValue)
    "vertical";
  check_eq ~msg:"the picker fills the available navigation height"
    (property_float renderer picker Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"the add action is a plain text button"
    (property_string renderer add Lui_protocol.VariantValue)
    "ghost";
  check_eq ~msg:"the refresh action is a plain text button"
    (property_string renderer refresh Lui_protocol.VariantValue)
    "ghost";
  check ~msg:"the picker renders the overflow menu in its header"
    (overflow <> -1);
  check_eq ~msg:"the picker does not render a second connection control"
    (descendant_count_with_identifier renderer main "button.connection")
    1;
  let settings_item =
    menu_item_with_text renderer overflow "Settings"
  in
  check ~msg:"the overflow menu exposes a Settings item"
    (settings_item <> -1);
  if settings_item <> -1 then dispatch application (Lui_protocol.Press settings_item);
  flush application;
  check ~msg:"the overflow menu routes settings through LG"
    (App.model application).settings_open;
  send application
    (Model.SyncFailed "graph_discovery_failed\nConnection refused");
  flush application;
  let main = main_root renderer application in
  let picker = child_with_identifier renderer main "screen.graph-picker" in
  let banner = child_with_identifier renderer picker "error.banner" in
  check ~msg:"the picker displays core failures" (banner <> -1);
  check_eq ~msg:"the failure code is presented as a user-facing title"
    (property_string renderer
       (descendant_with_identifier renderer banner "error.banner.code")
       Lui_protocol.TextValue)
    "Couldn't load graphs";
  check_eq ~msg:"the failure message remains visible"
    (property_string renderer
       (descendant_with_identifier renderer banner "error.banner.message")
       Lui_protocol.TextValue)
    "Connection refused"

let kotlin_graph_picker_uses_a_material_empty_state () =
  let application = App.create (kotlin_backend ()) in
  start application;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let picker =
    descendant_with_identifier renderer root "screen.graph-picker"
  in
  let title =
    descendant_with_identifier renderer picker "title.graph-picker"
  in
  let empty_state =
    descendant_with_identifier renderer picker "empty.graph-picker"
  in
  let add = descendant_with_identifier renderer picker "button.graph-add" in
  let refresh =
    descendant_with_identifier renderer picker "button.graphs.refresh"
  in
  check_eq ~msg:"the Material picker fills the available screen width"
    (property_string renderer picker Lui_protocol.CrossAlignment)
    "stretch";
  check_eq ~msg:"the Material title uses a compact app-bar scale"
    (property_int renderer title Lui_protocol.HeadingLevel)
    3;
  check ~msg:"an empty catalog renders a purposeful Material empty state"
    (empty_state <> -1);
  check_eq ~msg:"Add graph is the empty state's primary action"
    (property_string renderer add Lui_protocol.VariantValue)
    "primary";
  check_eq ~msg:"Add graph uses the Android Material add icon"
    (property_string renderer add Lui_protocol.InlineIconName)
    "app:add";
  check_eq ~msg:"Refresh uses the Android Material sync icon"
    (property_string renderer refresh Lui_protocol.InlineIconName)
    "app:sync-status"

let persisted_graph_loading_hides_the_launch_picker () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.ApplyGraphLoading true);
  flush application;
  let renderer = Lui_app.runtime application in
  let main = main_root renderer application in
  check ~msg:"a persisted graph renders the main loading state"
    (child_with_identifier renderer main "journals.loading" <> -1);
  check_eq ~msg:"the launch picker does not flash while a graph loads"
    (child_with_identifier renderer main "screen.graph-picker")
    (-1);
  send application (Model.ApplyGraphLoading false);
  flush application;
  check ~msg:"the empty catalog picker appears after loading completes"
    (child_with_identifier renderer (main_root renderer application)
       "screen.graph-picker"
    <> -1);
  send application (Model.ApplyGraphLoading true);
  flush application;
  let main = main_root renderer application in
  let loading = child_with_identifier renderer main "journals.loading" in
  check_eq ~msg:"an unselected catalog has a graph-specific loading label"
    (property_string renderer (List.nth (children renderer loading) 0)
       Lui_protocol.TextValue)
    "Loading graphs";
  check_eq ~msg:"the picker stays hidden until the catalog is ready"
    (child_with_identifier renderer main "screen.graph-picker")
    (-1);
  let cached =
    {
      (Model.initial ()) with
      Model.selected_graph_id = Some "local";
      graph_loading = true;
      outliner_rows =
        [ journal_outline_row "cached" "journal" "Cached" "Today" 20260827 0 ];
    }
  in
  check ~msg:"cached journals remain visible during a background reload"
    (View_base.journal_root_visible_ cached)

let kotlin_loading_and_errors_use_material_feedback_surfaces () =
  let application = App.create (kotlin_backend ()) in
  let local = graph "local" "Local graph" false true in
  start application;
  send application (Model.ApplyGraphLoading true);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let loading =
    descendant_with_identifier renderer root "journals.loading"
  in
  let spinner =
    descendant_with_identifier renderer loading "spinner.graph-loading"
  in
  check_eq ~msg:"Android graph restore uses Material progress feedback"
    (node renderer spinner)
    (Some Lui_protocol.Spinner);
  check_eq ~msg:"Android graph restore stays centered in the viewport"
    (property_string renderer loading Lui_protocol.MainAlignment)
    "center";
  send application (Model.ApplyGraphLoading false);
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graphs = [ local ];
         selected_graph_id = None;
       });
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.ShowGraphs;
  send application (Model.RequestDeleteGraph "local");
  send application Model.ConfirmDeleteGraph;
  send application (Model.DequeueEffect 1);
  send application
    (Model.ResolveEffect (1, false, "Could not delete graph"));
  flush application;
  let root = main_root renderer application in
  let surface =
    descendant_with_identifier renderer root "layout.error.banner"
  in
  let message =
    descendant_with_identifier renderer surface "error.banner"
  in
  check_eq ~msg:"Android failures use a Material error surface"
    (node renderer surface)
    (Some Lui_protocol.Alert);
  check_eq ~msg:"the Material error surface preserves the failure reason"
    (property_string renderer message Lui_protocol.TextValue)
    "Could not delete graph"

let graph_and_sync_actions_update_retained_status_in_place () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let chrome = children renderer navigation in
  let title = List.nth chrome 2 in
  let sidebar_control =
    List.nth (children renderer (List.nth chrome 1)) 0
  in
  let sync_control =
    List.nth (children renderer (List.nth chrome 3)) 0
  in
  let connection_control =
    List.nth (children renderer (List.nth chrome 4)) 0
  in
  send application Model.BeginSync;
  flush application;
  List.iter
    (fun control ->
       check_eq ~msg:"journal header actions keep semantic ghost styling"
         (property_string renderer control Lui_protocol.VariantValue)
         "ghost")
    [ sidebar_control; sync_control ];
  check ~msg:"the journal trailing action opens the calendar"
    (descendant_with_identifier renderer connection_control "button.journal-calendar" <> -1);
  check_eq ~msg:"the journal root leaves its default navigation title empty"
    (property_string renderer title Lui_protocol.TextValue)
    "";
  check_eq ~msg:"begin sync exposes progress"
    (property_string renderer sync_control Lui_protocol.AccessibilityLabel)
    "Syncing";
  check_eq ~msg:"sync changes retain the native status node"
    (List.nth (children renderer (List.nth chrome 3)) 0)
    sync_control;
  send application Model.SyncSucceeded;
  flush application;
  check_eq ~msg:"success is visible"
    (property_string renderer sync_control Lui_protocol.AccessibilityLabel)
    "Synced";
  send application (Model.SyncFailed "Network unavailable");
  flush application;
  check_eq ~msg:"the compact control matches main's failure label"
    (property_string renderer sync_control Lui_protocol.AccessibilityLabel)
    "Sync failed";
  dispatch application (Lui_protocol.Press
    (descendant_with_identifier renderer connection_control "button.journal-calendar"));
  flush application;
  check ~msg:"the calendar action reaches native presentation"
    (List.exists (function Model.PresentJournalCalendarEffect _ -> true | _ -> false)
       (App.model application).pending_effects)

let sync_details_render_projected_cursor_and_trigger_the_existing_pump () =
  let application = App.create (ios_backend ()) in
  let projection =
    {
      (empty_core_projection ()) with
      selected_graph_id = Some "work";
      graph_name = Some "Work";
      sync_connected = true;
      applied_server_t = Some 42;
      has_pending_semantic_operations = true;
      has_pending_sync_request = false;
    }
  in
  start application;
  send application (Model.SelectGraph "Work");
  send application (Model.ApplyCoreSnapshot projection);
  flush application;
  check_eq ~msg:"projected pending work keeps the compact status syncing"
    (App.model application).sync_state Model.SyncingState;
  let renderer = Lui_app.runtime application in
  let application_root = Lui_app.root_node application in
  let sync_button =
    descendant_with_identifier renderer application_root "sync.connected"
  in
  dispatch application (Lui_protocol.Press sync_button);
  flush application;
  check ~msg:"sync detail presentation is LG-owned"
    (App.model application).sync_details_open;
  let cursor =
    descendant_with_identifier renderer application_root "sync.cursor"
  in
  let pending =
    descendant_with_identifier renderer application_root "sync.pending"
  in
  let sheet =
    descendant_with_identifier renderer application_root "sheet.sync-status"
  in
  let form_node =
    descendant_with_identifier renderer application_root "form.sync-status"
  in
  let status_row =
    descendant_with_identifier renderer application_root "row.sync.status"
  in
  let done_button =
    descendant_with_identifier renderer application_root "button.sync.done"
  in
  let sync_now =
    descendant_with_identifier renderer application_root "button.sync-now"
  in
  check_eq ~msg:"sync details use main's native navigation Form sheet"
    (property_string renderer sheet Lui_protocol.StyleClass)
    "navigation-form";
  check_eq ~msg:"sync details expose native Form rows"
    (node renderer form_node)
    (Some Lui_protocol.Column);
  check_eq ~msg:"sync values use native Form rows"
    (node renderer status_row)
    (Some Lui_protocol.ListItem);
  check_eq ~msg:"Done stays in the native confirmation toolbar placement"
    (property_string renderer done_button Lui_protocol.StyleClass)
    "confirmation-action";
  check_eq ~msg:"Sync now uses the native Form button interaction"
    (node renderer sync_now)
    (Some Lui_protocol.Button);
  check_eq ~msg:"the authoritative server cursor is visible"
    (property_string renderer cursor Lui_protocol.TextValue)
    "42";
  check_eq ~msg:"pending semantic work is visible"
    (property_string renderer pending Lui_protocol.TextValue)
    "Waiting to save";
  dispatch application (Lui_protocol.Press sync_now);
  flush application;
  check_eq ~msg:"Sync now reuses the existing platform sync pump"
    (App.model application).pending_effects
    [ Model.SyncNowEffect 1 ]

let sync_details_show_the_last_sync_failure () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  send application (Model.SyncFailed "Network unavailable");
  send application Model.OpenSyncDetails;
  flush application;
  let renderer = Lui_app.runtime application in
  let error =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "sync.error"
  in
  check ~msg:"the sync failure has a stable status-sheet identifier"
    (error <> -1);
  check_eq ~msg:"the status sheet preserves the actionable failure reason"
    (property_string renderer error Lui_protocol.TextValue)
    "Network unavailable"

let pending_sync_patches_preserve_the_current_screen_and_cursor () =
  let full =
    {
      (empty_core_projection ()) with
      graph_name = Some "Work";
      sync_connected = true;
      applied_server_t = Some 42;
      has_pending_semantic_operations = true;
    }
  in
  let current =
    Model.update (Model.initial ()) (Model.ApplyCoreSnapshot full)
  in
  let patch =
    {
      (empty_core_projection ()) with
      is_pending_sync_patch = true;
      has_pending_semantic_operations = false;
      has_pending_sync_request = false;
    }
  in
  let updated = Model.update current (Model.ApplyCoreSnapshot patch) in
  check_eq ~msg:"pending transport patches do not clear graph state"
    updated.selected_graph (Some "Work");
  check_eq ~msg:"pending transport patches preserve the server cursor"
    updated.applied_server_t (Some 42);
  check ~msg:"pending transport patches update their owned sync flags"
    (not updated.has_pending_semantic_operations);
  check_eq ~msg:"finishing pending work clears the syncing indicator"
    (View_base.sync_indicator_label updated)
    "Synced";
  check_eq ~msg:"finishing pending work restores the green indicator"
    (View_base.sync_indicator_foreground updated)
    "success-foreground";
  let offline =
    Model.update
      { current with Model.sync_state = Model.OfflineState }
      (Model.ApplyCoreSnapshot patch)
  in
  check_eq ~msg:"a pending patch cannot invent a connection"
    (View_base.sync_indicator_label offline)
    "Not connected"

let outline_row uuid title =
  {
    Model.row_uuid = uuid;
    row_loaded = true;
    row_title = title;
    markup_json = "[]";
    youtube_target_url = None;
    row_breadcrumb = "";
    row_breadcrumbs = [];
    opens_as_page = false;
    depth = 0;
    has_children = false;
    is_collapsed = false;
    is_asset = false;
    asset_type = None;
    local_path = None;
    row_priority = None;
    row_status = None;
    tags = [];
    sync_status = None;
    page_id = "";
    journal_title = None;
    journal_day = None;
  }

let graph_catalog_patches_preserve_the_active_editor_state () =
  let current =
    {
      (Model.initial ()) with
      Model.composer_expanded = true;
      composer_draft = "Editing now";
      journal_outliner_rows =
        [
          journal_outline_row "block-a" "page-a" "Existing" "Journal"
            20260901 0;
        ];
    }
  in
  let graph = graph "graph-a" "Graph A" false true in
  let patch =
    {
      (empty_core_projection ()) with
      is_graph_catalog_patch = true;
      graph_name = Some "Graph A";
      selected_graph_id = Some "graph-a";
      graphs = [ graph ];
    }
  in
  let updated = Model.update current (Model.ApplyCoreSnapshot patch) in
  check_eq ~msg:"catalog refreshes preserve the active composer"
    updated.composer_draft "Editing now";
  check_eq ~msg:"catalog refreshes preserve journal rows"
    updated.journal_outliner_rows current.journal_outliner_rows;
  check_eq ~msg:"catalog refreshes update their owned graph list"
    updated.graphs [ graph ]

let sidebar_state_and_page_selection_are_owned_by_lg () =
  let favorite = { Model.uuid = "page-a"; title = "Favorite" } in
  let recent = { Model.uuid = "page-b"; title = "Recent" } in
  let journal_row =
    journal_outline_row "page-a-root" "page-a" "Loaded journal content"
      "Favorite" 20260829 0
  in
  let opened = Model.update (Model.initial ()) Model.OpenSidebar in
  let projected =
    Model.update opened
      (apply_core_snapshot None
         {
           Model.favorites = [ favorite ];
           recent_pages = [ recent ];
           selected_page = None;
           selected_page_is_tag = false;
           selected_page_is_property = false;
           related_rows = [];
           linked_reference_rows = [];
         }
         [] false "" [] [] None None [] [] [ journal_row ] false [])
  in
  let selected = Model.update projected (Model.SelectSidebarPage "page-a") in
  let selected_row =
    journal_outline_row "selected-page-row" "page-a" "Authoritative content"
      "Favorite" 20260829 0
  in
  let selected_sidebar =
    {
      Model.favorites = [ favorite ];
      recent_pages = [ recent ];
      selected_page = Some favorite;
      selected_page_is_tag = false;
      selected_page_is_property = false;
      related_rows = [];
      linked_reference_rows = [];
    }
  in
  let reconciled =
    Model.update selected
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "test-graph";
           sidebar = selected_sidebar;
           journal_outliner_rows = [ selected_row ];
           outliner_rows = [ selected_row ];
         })
  in
  let journals = Model.update selected Model.ShowJournals in
  check ~msg:"sidebar presentation is LG-owned" opened.sidebar_open;
  check_eq ~msg:"favorites come from the core projection" projected.favorites
    [ favorite ];
  check_eq ~msg:"recent pages come from the core projection"
    projected.recent_pages [ recent ];
  check_eq ~msg:"loaded sidebar pages expose their title immediately"
    selected.selected_page (Some favorite);
  check_eq ~msg:"loaded journals expose their retained rows immediately"
    selected.outliner_rows [ journal_row ];
  check_eq ~msg:"selected page snapshots preserve the loaded journal cache"
    reconciled.journal_outliner_rows [ journal_row ];
  check ~msg:"selecting a page dismisses the sidebar"
    (not selected.sidebar_open);
  check_eq ~msg:"page selection crosses the typed core boundary"
    selected.pending_effects
    [ Model.SelectSidebarPageEffect (1, "page-a") ];
  check_eq ~msg:"journals clears the selected core page"
    journals.pending_effects
    [
      Model.SelectSidebarPageEffect (1, "page-a");
      Model.ClearSelectedPageEffect 2;
    ]

let sidebar_renders_main_branch_navigation_identifiers () =
  let application = App.create (ios_backend ()) in
  let favorite = { Model.uuid = "page-a"; title = "Favorite" } in
  let current_graph = graph "current" "sync 2" false true in
  let remote_graph = graph "remote" "Remote graph" false true in
  let preparing_graph = graph "preparing" "Preparing graph" false false in
  let sidebar =
    {
      Model.favorites = [ favorite ];
      recent_pages = [];
      selected_page = None;
      selected_page_is_tag = false;
      selected_page_is_property = false;
      related_rows = [];
      linked_reference_rows = [];
    }
  in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graph_name = Some "sync 2";
         selected_graph_id = Some "current";
         graphs = [ current_graph; remote_graph; preparing_graph ];
         sidebar;
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let root = application_shell_root renderer application in
  check ~msg:"the native drawer starts from LG's closed state"
    (not (property_bool renderer root Lui_protocol.Selected));
  check ~msg:"the journal surface accepts horizontal sidebar gestures"
    (property_bool renderer root Lui_protocol.Enabled);
  send application Model.OpenSearch;
  flush application;
  check ~msg:"full-screen search owns the horizontal gesture"
    (not (property_bool renderer root Lui_protocol.Enabled));
  send application Model.CloseSearch;
  flush application;
  check ~msg:"closing search restores sidebar gestures"
    (property_bool renderer root Lui_protocol.Enabled);
  dispatch application
    (Lui_protocol.Press
       (descendant_with_identifier renderer root "button.sidebar"));
  flush application;
  check ~msg:"opening the sidebar patches the controlled drawer"
    (property_bool renderer root Lui_protocol.Selected);
  let sidebar_view =
    descendant_with_identifier renderer root "sidebar.navigation"
  in
  let sidebar_children = children renderer sidebar_view in
  let top_safe_area =
    if sidebar_children = [] then -1 else List.nth sidebar_children 0
  in
  let dismiss =
    child_with_identifier renderer sidebar_view "button.sidebar.dismiss"
  in
  let graph_switch =
    descendant_with_identifier renderer sidebar_view "button.graph-switch"
  in
  let journals =
    child_with_identifier renderer sidebar_view "link.sidebar.journals"
  in
  let flashcards =
    child_with_identifier renderer sidebar_view "link.sidebar.flashcards"
  in
  let graphs =
    child_with_identifier renderer sidebar_view "link.sidebar.graphs"
  in
  let favorites =
    descendant_with_identifier renderer sidebar_view "section.sidebar.favorites"
  in
  let favorites_heading = List.nth (children renderer favorites) 0 in
  let favorites_heading_children = children renderer favorites_heading in
  let favorites_heading_top = List.nth favorites_heading_children 0 in
  let favorites_heading_content = List.nth favorites_heading_children 1 in
  let favorites_heading_bottom = List.nth favorites_heading_children 2 in
  let favorites_heading_icon =
    List.nth (children renderer favorites_heading_content) 0
  in
  let recent =
    descendant_with_identifier renderer sidebar_view "section.sidebar.recent"
  in
  let favorite_link =
    child_with_identifier renderer favorites "link.sidebar.page.page-a"
  in
  check_eq ~msg:"sidebar keeps the main branch content inset"
    (property_int renderer sidebar_view Lui_protocol.PaddingValue)
    12;
  let pages_scroll =
    descendant_with_identifier renderer sidebar_view "scroll.sidebar.pages"
  in
  check ~msg:"Favorites and Recent have their own scroll region"
    (pages_scroll <> -1);
  check_eq ~msg:"top navigation stays outside the scroll region"
    (descendant_with_identifier renderer pages_scroll "link.sidebar.journals")
    (-1);
  check_eq ~msg:"scrolling starts with Favorites"
    (descendant_with_identifier renderer pages_scroll
       "section.sidebar.favorites")
    favorites;
  check_eq
    ~msg:
      "the full-height drawer reserves sidebar status-bar space in LG"
    (if top_safe_area = -1 then None else node renderer top_safe_area)
    (Some Lui_protocol.Box);
  check_eq
    ~msg:"the sidebar spacer plus the following 4-point gap matches main"
    (property_int renderer top_safe_area Lui_protocol.HeightValue)
    48;
  check_eq
    ~msg:
      "the graph switch follows the explicit full-screen safe-area spacer"
    (descendant_with_identifier renderer (List.nth sidebar_children 1)
       "button.graph-switch")
    graph_switch;
  check_eq ~msg:"sidebar keeps the main branch row spacing"
    (property_int renderer sidebar_view Lui_protocol.Gap)
    4;
  check_eq
    ~msg:"the main surface owns dismissal instead of rendering a close row"
    dismiss (-1);
  check ~msg:"sidebar keeps the graph switch identifier" (graph_switch <> -1);
  check_eq ~msg:"the graph switch displays the selected graph name"
    (property_string renderer graph_switch Lui_protocol.TextValue)
    "sync 2";
  check_eq ~msg:"the graph switch uses the reusable navigation heading role"
    (property_string renderer graph_switch Lui_protocol.RoleValue)
    "navigation-heading";
  check_eq ~msg:"the graph switch keeps the disclosure affordance"
    (property_string renderer graph_switch Lui_protocol.InlineIconName)
    "app:chevron-down";
  check_eq ~msg:"the graph switch places its disclosure icon after the title"
    (property_string renderer graph_switch Lui_protocol.IconPlacementValue)
    "trailing";
  check_eq ~msg:"sidebar destinations use native navigation rows"
    (property_string renderer journals Lui_protocol.RoleValue)
    "navigation";
  check_eq ~msg:"journals keeps its navigation icon"
    (property_string renderer journals Lui_protocol.InlineIconName)
    "app:calendar";
  check ~msg:"the current journal destination keeps its selected row"
    (property_bool renderer journals Lui_protocol.Selected);
  check_eq ~msg:"flashcards keeps its navigation icon"
    (property_string renderer flashcards Lui_protocol.InlineIconName)
    "app:flashcards";
  check_eq ~msg:"graphs keeps its navigation icon"
    (property_string renderer graphs Lui_protocol.InlineIconName)
    "app:folder";
  check ~msg:"sidebar keeps the recent section identifier" (recent <> -1);
  check_eq ~msg:"sidebar pages keep their document icon"
    (property_string renderer favorite_link Lui_protocol.InlineIconName)
    "app:document";
  check_eq ~msg:"sidebar section glyphs match main's caption2 metrics"
    (property_int renderer favorites_heading_icon Lui_protocol.WidthValue)
    14;
  check_eq ~msg:"sidebar section headings keep main's top spacing"
    (property_int renderer favorites_heading_top Lui_protocol.HeightValue)
    16;
  check_eq ~msg:"sidebar section headings keep main's bottom spacing"
    (property_int renderer favorites_heading_bottom Lui_protocol.HeightValue)
    6;
  dispatch application (Lui_protocol.Press favorite_link);
  flush application;
  check ~msg:"page selection closes the controlled drawer"
    (not (property_bool renderer root Lui_protocol.Selected));
  check_eq ~msg:"sidebar page presses reuse the typed selection effect"
    (App.model application).pending_effects
    [ Model.SelectSidebarPageEffect (1, "page-a") ];
  dispatch application
    (Lui_protocol.Press
       (descendant_with_identifier renderer root "button.sidebar"));
  flush application;
  let reopened_sidebar =
    descendant_with_identifier renderer root "sidebar.navigation"
  in
  let switch_button =
    descendant_with_identifier renderer reopened_sidebar "button.graph-switch"
  in
  dispatch application (Lui_protocol.Press switch_button);
  flush application;
  let menu =
    descendant_with_identifier renderer reopened_sidebar "menu.graph-switch"
  in
  check ~msg:"the graph heading opens a native menu" (menu <> -1);
  if menu <> -1 then begin
    let current_item =
      child_with_identifier renderer menu "menu.graph.current"
    in
    let preparing_item =
      child_with_identifier renderer menu "menu.graph.preparing"
    in
    check ~msg:"the current graph is selected in the native menu"
      (property_bool renderer current_item Lui_protocol.Selected);
    check ~msg:"graphs that are not ready stay disabled"
      (not (property_bool renderer preparing_item Lui_protocol.Enabled));
    check_eq ~msg:"opening the graph menu keeps the current destination"
      (App.model application).destination Model.JournalsDestination;
    check ~msg:"opening the graph menu keeps the drawer visible"
      (property_bool renderer root Lui_protocol.Selected);
    dispatch application (Lui_protocol.Dismiss menu);
    flush application;
    check_eq ~msg:"native menu dismissal removes the retained menu"
      (descendant_with_identifier renderer reopened_sidebar
         "menu.graph-switch")
      (-1);
    dispatch application (Lui_protocol.Press switch_button);
    flush application;
    let reopened_menu =
      descendant_with_identifier renderer reopened_sidebar
        "menu.graph-switch"
    in
    if reopened_menu <> -1 then begin
      let remote_item =
        child_with_identifier renderer reopened_menu "menu.graph.remote"
      in
      dispatch application (Lui_protocol.Press remote_item);
      flush application;
      check_eq
        ~msg:"choosing another graph reuses the typed open-graph effect"
        (App.model application).pending_effects
        [
          Model.SelectSidebarPageEffect (1, "page-a");
          Model.OpenGraphEffect (2, "remote");
        ];
      check ~msg:"choosing a graph closes the controlled drawer"
        (not (property_bool renderer root Lui_protocol.Selected))
    end
  end

let sidebar_drag_reserves_app_navigation () =
  let application = App.create (ios_backend ()) in
  let sidebar =
    {
      Model.favorites = [];
      recent_pages = [];
      selected_page = None;
      selected_page_is_tag = false;
      selected_page_is_property = false;
      related_rows = [];
      linked_reference_rows = [];
    }
  in
  start application;
  send application
    (apply_core_snapshot None sidebar [] false "" [] [] None None [] [] []
       false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = application_shell_root renderer application in
  check ~msg:"the journal surface accepts horizontal sidebar gestures"
    (property_bool renderer root Lui_protocol.Enabled);
  send application (Model.RequestAppNode "node-a");
  flush application;
  check ~msg:"node navigation reserves the leading-edge back gesture"
    (not (property_bool renderer root Lui_protocol.Enabled))

let selected_sidebar_pages_render_their_outliner_and_related_content () =
  let application = App.create (ios_backend ()) in
  let page = { Model.uuid = "page-a"; title = "Project" } in
  let related_row =
    {
      (outline_row "reference" "Linked from journal") with
      row_breadcrumb = "Journal";
    }
  in
  let content_row =
    {
      related_row with
      Model.row_uuid = "content";
      row_title = "Page content";
    }
  in
  let sidebar =
    {
      Model.favorites = [ page ];
      recent_pages = [ page ];
      selected_page = Some page;
      selected_page_is_tag = false;
      selected_page_is_property = false;
      related_rows = [ related_row ];
      linked_reference_rows = [];
    }
  in
  start application;
  send application
    (apply_core_snapshot None sidebar [] false "" [] [] None None [] []
       [ content_row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let title =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "title.main"
  in
  let related =
    descendant_with_identifier renderer outliner
      "section.node.linked-references"
  in
  let related_group =
    parent_with_child_identifier renderer outliner "outliner.block.reference"
  in
  let add_first =
    descendant_with_identifier renderer outliner
      "button.outliner.add-first-block"
  in
  let content =
    descendant_with_identifier renderer outliner "outliner.block.content"
  in
  let page_title =
    descendant_with_identifier renderer outliner "title.selected-page"
  in
  let page_title_layout =
    descendant_with_identifier renderer outliner "layout.selected-page.title"
  in
  check_eq ~msg:"selected pages own the main header title"
    (property_string renderer title Lui_protocol.TextValue)
    "Project";
  check ~msg:"selected pages render their core-projected linked references"
    (related <> -1);
  check_eq
    ~msg:"related breadcrumbs and rows use main's zero-spacing stack"
    (property_int renderer related_group Lui_protocol.Gap)
    0;
  check ~msg:"selected pages render their own projected outliner rows"
    (content <> -1);
  check ~msg:"selected non-tag pages repeat their title in the content surface"
    (page_title <> -1);
  check_eq ~msg:"selected page titles use main's title2 typography"
    (property_int renderer page_title Lui_protocol.HeadingLevel)
    3;
  check_eq
    ~msg:"selected page titles preserve the combined main horizontal inset"
    (property_int renderer page_title_layout Lui_protocol.PaddingHorizontal)
    16;
  check ~msg:"non-empty selected pages hide the add-first-block action"
    (add_first = -1)

let flashcard_presentation_and_review_state_are_owned_by_lg () =
  let card =
    flashcard "card-a" "Remember […]" "Remember this"
      [ flashcard_answer "answer-a" 0 "Child answer" ]
      true
  in
  let projected =
    Model.update (Model.initial ())
      (apply_core_snapshot None (empty_sidebar_projection ()) [ card ] false ""
         [] [] None None [] [] [] false [])
  in
  let shown = Model.update projected Model.ShowFlashcards in
  let cloze = Model.update shown Model.RevealFlashcardCloze in
  let answer = Model.update cloze Model.RevealFlashcardAnswer in
  let reviewed = Model.update answer (Model.ReviewFlashcard "good") in
  check_eq ~msg:"the primary destination is LG-owned" shown.destination
    Model.FlashcardsDestination;
  check ~msg:"opening flashcards closes the sidebar"
    (not shown.sidebar_open);
  check_eq
    ~msg:"entering flashcards clears page context before loading due cards"
    shown.pending_effects
    [ Model.ClearSelectedPageEffect 1; Model.LoadFlashcardsEffect 2 ];
  check ~msg:"cloze reveal is retained in LG state"
    cloze.flashcard_cloze_revealed;
  check ~msg:"answer reveal is retained in LG state"
    answer.flashcard_answer_revealed;
  check_eq ~msg:"ratings use the current projected card identity"
    reviewed.pending_effects
    [
      Model.ClearSelectedPageEffect 1;
      Model.LoadFlashcardsEffect 2;
      Model.ReviewFlashcardEffect (3, "card-a", "good");
    ]

let load_older_journals_coalesces_while_pending () =
  let requested = Model.update (Model.initial ()) Model.LoadOlderJournals in
  let duplicate_pending =
    Model.update requested Model.LoadOlderJournals
  in
  let in_flight = Model.update requested (Model.DequeueEffect 1) in
  let duplicate_in_flight =
    Model.update in_flight Model.LoadOlderJournals
  in
  let resolved = Model.update in_flight (Model.ResolveEffect (1, true, "")) in
  let requested_again = Model.update resolved Model.LoadOlderJournals in
  check_eq
    ~msg:"a pending journal pagination request should absorb duplicate appears"
    duplicate_pending.pending_effects
    [ Model.LoadOlderJournalsEffect 1 ];
  check_eq
    ~msg:
      "an in-flight journal pagination request should absorb duplicate \
       appears"
    duplicate_in_flight.pending_effects [];
  check_eq
    ~msg:"pagination should become available again after the request resolves"
    requested_again.pending_effects
    [ Model.LoadOlderJournalsEffect 2 ]

let unrelated_snapshots_preserve_the_journal_pagination_window () =
  let first_day =
    journal_outline_row "day-a-root" "page-a" "First" "August 29th" 20260829 0
  in
  let older_day =
    journal_outline_row "day-b-root" "page-b" "Older" "August 28th" 20260828 0
  in
  let initial =
    Model.update (Model.initial ())
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           has_older_journals = true;
           outliner_rows = [ first_day ];
         })
  in
  let unrelated =
    Model.update initial
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           has_older_journals = false;
           outliner_rows = [ first_day; older_day ];
         })
  in
  let loading =
    Model.update
      (Model.update initial Model.LoadOlderJournals)
      (Model.DequeueEffect 1)
  in
  let captured_row =
    journal_outline_row "captured-block" "page-a" "Captured now"
      "August 29th" 20260829 0
  in
  let capturing =
    {
      initial with
      Model.in_flight_effects =
        [ Model.SendCaptureEffect (7, "Captured now") ];
    }
  in
  let captured =
    Model.update capturing
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           has_older_journals = true;
           outliner_rows = [ first_day; captured_row ];
         })
  in
  let paginated =
    Model.update loading
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           has_older_journals = false;
           outliner_rows = [ first_day; older_day ];
         })
  in
  check_eq ~msg:"unrelated snapshots keep the visible journal window"
    unrelated.outliner_rows [ first_day ];
  check_eq ~msg:"unrelated snapshots keep the retained journal cache"
    unrelated.journal_outliner_rows [ first_day ];
  check ~msg:"unrelated snapshots keep pagination available"
    unrelated.has_older_journals;
  check_eq ~msg:"a capture response refreshes today's visible journal"
    captured.outliner_rows [ first_day; captured_row ];
  check_eq ~msg:"a capture response refreshes the retained journal cache"
    captured.journal_outliner_rows [ first_day; captured_row ];
  check_eq ~msg:"a journal pagination response expands the visible window"
    paginated.outliner_rows [ first_day; older_day ];
  check_eq ~msg:"a journal pagination response expands the retained cache"
    paginated.journal_outliner_rows [ first_day; older_day ];
  check ~msg:"pagination accepts the authoritative continuation state"
    (not paginated.has_older_journals)

let journal_node_insertion_keeps_the_rendered_sibling_position () =
  let application = App.create (ios_backend ()) in
  let first_row =
    journal_outline_row "a" "today" "First" "Today" 20260906 0
  in
  let last_row = journal_outline_row "z" "today" "Last" "Today" 20260906 0 in
  let inserted_row =
    journal_outline_row "b" "today" "Inserted" "Today" 20260906 0
  in
  let route =
    {
      (node_projection "today" "today" "Today" [] []) with
      Model.node_outliner_editing =
        Some
          {
            Model.editing_uuid = "a";
            editing_title = "First";
            caret_utf16_offset = 5;
          };
      node_outliner_rows = [ first_row; last_row ];
    }
  in
  let projection =
    {
      (empty_core_projection ()) with
      selected_graph_id = Some "graph-a";
      node_routes = [ route ];
      outliner_rows = [ first_row; last_row ];
    }
  in
  start application;
  send application (Model.RequestAppNode "today");
  send application (Model.ApplyCoreSnapshot projection);
  flush application;
  send application
    (Model.ApplyCoreSnapshot
       {
         projection with
         node_routes =
           [
             {
               route with
               Model.node_outliner_editing =
                 Some
                   {
                     Model.editing_uuid = "b";
                     editing_title = "Inserted";
                     caret_utf16_offset = 8;
                   };
               node_outliner_rows = [ first_row; inserted_row; last_row ];
             };
           ];
         outliner_rows = [ first_row; inserted_row; last_row ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let screen =
    descendant_with_identifier renderer navigation "screen.node"
  in
  let outliner =
    descendant_with_identifier renderer screen "list.outliner"
  in
  let rec row_identifiers id =
    let identifier = property_string renderer id Lui_protocol.AccessibilityIdentifier in
    if String.starts_with ~prefix:"outliner.block." identifier then [identifier]
    else List.fold_left (fun acc child -> List.rev_append (row_identifiers child) acc)
      [] (children renderer id) |> List.rev
  in
  let rows = row_identifiers outliner in
  check_eq
    ~msg:"inserting in the middle must retain the rendered sibling order"
    rows
    [ "outliner.block.a"; "outliner.block.b"; "outliner.block.z" ]

let capture_refreshes_the_retained_journal_behind_a_node_route () =
  let first_row =
    journal_outline_row "first" "today" "First" "Today" 20260906 0
  in
  let captured_row =
    journal_outline_row "captured" "today" "Captured" "Today" 20260906 0
  in
  let route =
    {
      (node_projection "today" "today" "Today" [] []) with
      Model.node_outliner_rows = [ first_row; captured_row ];
    }
  in
  let current =
    {
      (Model.initial ()) with
      Model.selected_graph_id = Some "graph-a";
      journal_outliner_rows = [ first_row ];
      node_routes = [ route ];
      in_flight_effects = [ Model.SendCaptureEffect (7, "Captured") ];
    }
  in
  let updated =
    Model.update current
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           node_routes = [ route ];
           journal_outliner_rows = [ first_row; captured_row ];
           outliner_rows = [ first_row; captured_row ];
         })
  in
  check_eq ~msg:"capture must update the mounted journal behind navigation"
    updated.journal_outliner_rows [ first_row; captured_row ]

let recent_journal_edits_refresh_the_retained_journals_pane () =
  let page = { Model.uuid = "today"; title = "Today" } in
  let original =
    journal_outline_row "first" "today" "Original" "Today" 20260906 0
  in
  let edited = { original with Model.row_title = "Edited from Recent" } in
  let inserted =
    journal_outline_row "inserted" "today" "Inserted" "Today" 20260906 0
  in
  let current =
    {
      (Model.initial ()) with
      Model.selected_graph_id = Some "graph-a";
      selected_page = Some page;
      journal_outliner_rows = [ original ];
      outliner_rows = [ original ];
    }
  in
  let edited_page =
    Model.update current
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           sidebar =
             {
               (empty_sidebar_projection ()) with
               selected_page = Some page;
             };
           journal_outliner_rows = [ edited; inserted ];
           outliner_rows = [ edited; inserted ];
         })
  in
  let updated =
    Model.update
      (Model.update edited_page Model.ShowJournals)
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           journal_outliner_rows = [ edited; inserted ];
           outliner_rows = [ edited; inserted ];
         })
  in
  check_eq ~msg:"returning from a Recent page refreshes the retained Journals data"
    updated.journal_outliner_rows [ edited; inserted ]

let synchronized_capture_refreshes_an_already_visible_journal () =
  let first_row =
    journal_outline_row "first" "today" "First" "Today" 20260906 0
  in
  let captured_row =
    journal_outline_row "captured" "today" "Captured" "Today" 20260906 0
  in
  let current =
    {
      (Model.initial ()) with
      Model.selected_graph_id = Some "graph-a";
      journal_outliner_rows = [ first_row ];
      outliner_rows = [ first_row ];
    }
  in
  let updated =
    Model.update current
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           journal_outliner_rows = [ first_row; captured_row ];
           outliner_rows = [ first_row; captured_row ];
         })
  in
  check_eq ~msg:"a sync snapshot must expose captures without restarting"
    updated.outliner_rows [ first_row; captured_row ]

let journal_refresh_applies_edits_deletions_and_a_new_day_without_loading_older_days
    () =
  let old_row =
    journal_outline_row "old" "yesterday" "Old" "Yesterday" 20260905 0
  in
  let deleted_row =
    journal_outline_row "deleted" "yesterday" "Deleted" "Yesterday" 20260905 0
  in
  let edited_row = { old_row with Model.row_title = "Edited" } in
  let today_row =
    journal_outline_row "today" "today" "New day" "Today" 20260906 0
  in
  let older_row =
    journal_outline_row "older" "older" "Older" "Older" 20260904 0
  in
  let current =
    {
      (Model.initial ()) with
      Model.selected_graph_id = Some "graph-a";
      journal_outliner_rows = [ old_row; deleted_row ];
      outliner_rows = [ old_row; deleted_row ];
    }
  in
  let updated =
    Model.update current
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           selected_graph_id = Some "graph-a";
           outliner_rows = [ today_row; edited_row; older_row ];
         })
  in
  check_eq ~msg:"refresh current days without silently expanding pagination"
    updated.journal_outliner_rows [ today_row; edited_row ]

let flashcard_reveal_state_resets_only_when_the_current_card_changes () =
  let first_card =
    flashcard "card-a" "First […]" "First answer" [] true
  in
  let same_card =
    flashcard "card-a" "Updated […]" "Updated answer" [] true
  in
  let next_card =
    flashcard "card-b" "Second […]" "Second answer" [] true
  in
  let projected =
    Model.update (Model.initial ())
      (apply_core_snapshot None (empty_sidebar_projection ()) [ first_card ]
         false "" [] [] None None [] [] [] false [])
  in
  let revealed =
    Model.update
      (Model.update projected Model.RevealFlashcardCloze)
      Model.RevealFlashcardAnswer
  in
  let refreshed =
    Model.update revealed
      (apply_core_snapshot None (empty_sidebar_projection ()) [ same_card ]
         false "" [] [] None None [] [] [] false [])
  in
  let advanced =
    Model.update refreshed
      (apply_core_snapshot None (empty_sidebar_projection ()) [ next_card ]
         false "" [] [] None None [] [] [] false [])
  in
  check ~msg:"a refresh of the same card retains its reveal state"
    refreshed.flashcard_cloze_revealed;
  check ~msg:"a refresh of the same card retains its answer state"
    refreshed.flashcard_answer_revealed;
  check ~msg:"advancing cards hides the next cloze"
    (not advanced.flashcard_cloze_revealed);
  check ~msg:"advancing cards hides the next answer"
    (not advanced.flashcard_answer_revealed);
  check_eq ~msg:"reviewing an empty queue is a no-op"
    (Model.update (Model.initial ()) (Model.ReviewFlashcard "again"))
      .pending_effects
    []

let flashcards_render_the_main_branch_reveal_and_rating_contract () =
  let application = App.create (ios_backend ()) in
  let card =
    flashcard "card-a" "Remember […]" "Remember this"
      [ flashcard_answer "answer-a" 0 "Child answer" ]
      true
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [ card ] false ""
       [] [] None None [] [] [] false []);
  send application Model.ShowFlashcards;
  flush application;
  let renderer = Lui_app.runtime application in
  let main = main_root renderer application in
  let screen = child_with_identifier renderer main "screen.flashcards" in
  let review =
    descendant_with_identifier renderer screen "layout.flashcards.review"
  in
  let review_content =
    descendant_with_identifier renderer screen
      "layout.flashcards.review-content"
  in
  let top_spacer =
    descendant_with_identifier renderer screen "spacer.flashcards.top"
  in
  let bottom_spacer =
    descendant_with_identifier renderer screen "spacer.flashcards.bottom"
  in
  let status =
    descendant_with_identifier renderer screen "row.flashcards.status"
  in
  let question_card =
    descendant_with_identifier renderer screen "card.flashcard.question"
  in
  let question =
    descendant_with_identifier renderer screen "flashcard.question"
  in
  let show_cloze =
    descendant_with_identifier renderer screen "button.flashcard.show-cloze"
  in
  let show_cloze_row =
    parent_with_child_identifier renderer screen "button.flashcard.show-cloze"
  in
  check_eq ~msg:"review content keeps main's section spacing"
    (property_int renderer review_content Lui_protocol.Gap)
    18;
  check_eq ~msg:"review content keeps main's edge inset"
    (property_int renderer review Lui_protocol.PaddingHorizontal)
    20;
  check_eq ~msg:"review content keeps main's top inset"
    (property_int renderer top_spacer Lui_protocol.HeightValue)
    18;
  check_eq ~msg:"review content keeps main's bottom inset"
    (property_int renderer bottom_spacer Lui_protocol.HeightValue)
    24;
  check_eq ~msg:"due count is one native status row"
    (node renderer status)
    (Some Lui_protocol.Row);
  check_eq ~msg:"the question uses the themed card surface"
    (property_string renderer question_card Lui_protocol.BackgroundValue)
    "surface";
  check_eq ~msg:"the question card matches main's corner radius"
    (property_int renderer question_card Lui_protocol.CornerRadius)
    18;
  check_eq ~msg:"the question card matches main's content inset"
    (property_int renderer question_card Lui_protocol.PaddingValue)
    22;
  check_eq ~msg:"the reveal action keeps main's minimum height"
    (property_int renderer show_cloze Lui_protocol.MinHeight)
    50;
  check_eq
    ~msg:
      "the reveal action grows across a row without consuming vertical space"
    (node renderer show_cloze_row)
    (Some Lui_protocol.Row);
  check_eq ~msg:"the reveal action uses the accent fill"
    (property_string renderer show_cloze Lui_protocol.BackgroundValue)
    "primary";
  check_eq ~msg:"the reveal action centers its native button label"
    (property_string renderer show_cloze Lui_protocol.TextAlignment)
    "center";
  check_eq ~msg:"the reveal action matches main's emphasized label"
    (property_string renderer show_cloze Lui_protocol.StyleClass)
    "semibold";
  check_eq ~msg:"clozes start hidden"
    (property_string renderer question Lui_protocol.TextValue)
    "Remember […]";
  dispatch application (Lui_protocol.Press show_cloze);
  flush application;
  check_eq ~msg:"cloze reveal patches the retained question"
    (property_string renderer question Lui_protocol.TextValue)
    "Remember this";
  let show_answer =
    descendant_with_identifier renderer screen "button.flashcard.show-answer"
  in
  dispatch application (Lui_protocol.Press show_answer);
  flush application;
  let answer_row =
    descendant_with_identifier renderer screen "flashcard.answer.0"
  in
  let answer_divider =
    descendant_with_identifier renderer screen "flashcard.answer-divider"
  in
  let good =
    descendant_with_identifier renderer screen "button.flashcard.rating.good"
  in
  check_eq ~msg:"revealed answers use main's full-width semantic divider"
    (node renderer answer_divider)
    (Some Lui_protocol.Divider);
  check_eq ~msg:"answer children appear after reveal"
    (property_string renderer answer_row Lui_protocol.TextValue)
    "Child answer";
  check_eq ~msg:"rating actions center their native button labels"
    (property_string renderer good Lui_protocol.TextAlignment)
    "center";
  check_eq ~msg:"rating actions match main's emphasized labels"
    (property_string renderer good Lui_protocol.StyleClass)
    "semibold";
  dispatch application (Lui_protocol.Press good);
  flush application;
  check_eq ~msg:"rating controls publish the typed review effect"
    (App.model application).pending_effects
    [
      Model.ClearSelectedPageEffect 1;
      Model.LoadFlashcardsEffect 2;
      Model.ReviewFlashcardEffect (3, "card-a", "good");
    ]

let flashcards_render_empty_and_non_cloze_control_states () =
  let application = App.create (ios_backend ()) in
  start application;
  send application Model.ShowFlashcards;
  flush application;
  let renderer = Lui_app.runtime application in
  let main = main_root renderer application in
  let screen = child_with_identifier renderer main "screen.flashcards" in
  let empty_state =
    descendant_with_identifier renderer screen "layout.flashcards.empty"
  in
  let empty_children = children renderer empty_state in
  let empty_icon = List.nth empty_children 0 in
  let empty_title = List.nth empty_children 1 in
  let empty_description = List.nth empty_children 2 in
  check ~msg:"an empty due queue preserves the existing empty state"
    (empty_state <> -1);
  check_eq ~msg:"empty and review layouts share a gap-free root container"
    (node renderer screen)
    (Some Lui_protocol.Column);
  check_eq ~msg:"hidden review content cannot shift the empty-state center"
    (property_int renderer screen Lui_protocol.Gap)
    0;
  check_eq ~msg:"hidden review content does not leave a layout sibling"
    (List.length (children renderer screen))
    1;
  check_eq ~msg:"the empty state fills the page before centering"
    (property_float renderer empty_state Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"the empty state is vertically centered like main"
    (property_string renderer empty_state Lui_protocol.MainAlignment)
    "center";
  check_eq ~msg:"the empty state is horizontally centered like main"
    (property_string renderer empty_state Lui_protocol.CrossAlignment)
    "center";
  check_eq ~msg:"the empty state uses the flashcards navigation icon"
    (property_string renderer empty_icon Lui_protocol.IconName)
    "app:flashcards";
  check_eq ~msg:"the empty title uses main's title2 typography"
    (property_int renderer empty_title Lui_protocol.HeadingLevel)
    3;
  check_eq ~msg:"the empty description is centered"
    (property_string renderer empty_description Lui_protocol.TextAlignment)
    "center";
  check_eq ~msg:"the empty description uses secondary foreground"
    (property_string renderer empty_description Lui_protocol.ForegroundValue)
    "muted-foreground";
  send application
    (apply_core_snapshot None (empty_sidebar_projection ())
       [ flashcard "card-a" "Plain question" "Plain question" [] false ]
       false "" [] [] None None [] [] [] false []);
  flush application;
  let main = main_root renderer application in
  let screen = child_with_identifier renderer main "screen.flashcards" in
  check ~msg:"cards without a cloze skip the cloze control"
    (descendant_with_identifier renderer screen "button.flashcard.show-cloze"
    = -1);
  check ~msg:"cards without a cloze can reveal their answer immediately"
    (descendant_with_identifier renderer screen "button.flashcard.show-answer"
    <> -1)

let sidebar_flashcards_link_selects_the_flashcard_destination () =
  let application = App.create (ios_backend ()) in
  start application;
  send application Model.OpenSidebar;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = application_shell_root renderer application in
  let sidebar =
    descendant_with_identifier renderer root "sidebar.navigation"
  in
  let link =
    child_with_identifier renderer sidebar "link.sidebar.flashcards"
  in
  dispatch application (Lui_protocol.Press link);
  flush application;
  check_eq ~msg:"the existing sidebar link enters the LG destination"
    (App.model application).destination Model.FlashcardsDestination;
  check ~msg:"selecting flashcards closes the controlled drawer"
    (not (property_bool renderer root Lui_protocol.Selected))

let graph_catalog_and_lifecycle_state_are_owned_by_lg () =
  let local = graph "local" "Local graph" false true in
  let remote = graph "remote" "Remote graph" true true in
  let preparing = graph "preparing" "Preparing graph" false false in
  let projection =
    {
      (empty_core_projection ()) with
      graph_name = Some "Local graph";
      selected_graph_id = Some "local";
      graphs = [ local; remote; preparing ];
      is_graph_encrypted = false;
      is_graph_unlocked = true;
    }
  in
  let projected =
    Model.update (Model.initial ()) (Model.ApplyCoreSnapshot projection)
  in
  let with_local =
    Model.update projected (Model.ApplyLocalGraphIds [ "local" ])
  in
  let shown =
    Model.update
      (Model.update with_local Model.OpenSidebar)
      Model.ShowGraphs
  in
  let refreshed = Model.update shown Model.RefreshGraphs in
  let rejected =
    Model.update refreshed (Model.RequestOpenGraph "preparing")
  in
  let opened = Model.update refreshed (Model.RequestOpenGraph "remote") in
  let create_open = Model.update shown Model.OpenCreateGraph in
  let named =
    Model.update create_open (Model.ChangeNewGraphName " New graph ")
  in
  let encrypted = Model.update named (Model.ToggleNewGraphEncrypted false) in
  let create_failed =
    {
      encrypted with
      Model.effect_error = Some "graph_create_failed\nServer rejected it";
    }
  in
  let create_dismissed =
    Model.update create_failed Model.DismissCreateGraph
  in
  let submitted = Model.update encrypted Model.SubmitCreateGraph in
  let remote_delete =
    Model.update shown (Model.RequestDeleteGraph "remote")
  in
  let delete_requested =
    Model.update shown (Model.RequestDeleteGraph "local")
  in
  let delete_confirmed =
    Model.update delete_requested Model.ConfirmDeleteGraph
  in
  check_eq ~msg:"the catalog is projected into LG state" projected.graphs
    [ local; remote; preparing ];
  check_eq ~msg:"downloaded graph identity comes from the platform boundary"
    with_local.local_graph_ids [ "local" ];
  check_eq ~msg:"graphs is a primary LG destination" shown.destination
    Model.GraphsDestination;
  check ~msg:"opening graphs closes the drawer" (not shown.sidebar_open);
  check_eq ~msg:"refresh crosses the typed effect boundary"
    refreshed.pending_effects
    [ Model.RefreshGraphsEffect 1 ];
  check_eq ~msg:"preparing graphs cannot be opened" rejected.pending_effects
    refreshed.pending_effects;
  check_eq ~msg:"ready graphs publish their stable id" opened.pending_effects
    [ Model.RefreshGraphsEffect 1; Model.OpenGraphEffect (2, "remote") ];
  check ~msg:"the add sheet is LG-owned" create_open.create_graph_open;
  check ~msg:"new graphs preserve main's encrypted-by-default behavior"
    create_open.new_graph_encrypted;
  check ~msg:"dismissing the add graph sheet closes it"
    (not create_dismissed.create_graph_open);
  check_eq ~msg:"dismissing the add graph sheet clears stale input"
    create_dismissed.new_graph_name "";
  check ~msg:"dismissing restores the encrypted-by-default form state"
    create_dismissed.new_graph_encrypted;
  check_eq ~msg:"dismissing clears the sheet's stale error"
    create_dismissed.effect_error None;
  check_eq ~msg:"graph creation trims its name and preserves encryption"
    submitted.pending_effects
    [ Model.CreateGraphEffect (1, "New graph", false) ];
  check_eq ~msg:"deletion confirmation retains the selected graph"
    delete_requested.pending_graph_deletion (Some local);
  check_eq ~msg:"remote-only graphs cannot enter local deletion"
    remote_delete.pending_graph_deletion None;
  check_eq ~msg:"confirming deletion publishes a platform effect"
    delete_confirmed.pending_effects
    [ Model.DeleteLocalGraphEffect (1, "local") ]

let graph_picker_surfaces_open_graph_effect_failures () =
  let remote = graph "remote" "Remote graph" true true in
  let ready = { (Model.initial ()) with graphs = [ remote ] } in
  let requested = Model.update ready (Model.RequestOpenGraph "remote") in
  let in_flight = Model.update requested (Model.DequeueEffect 1) in
  let failed =
    Model.update in_flight
      (Model.ResolveEffect
         (1, false, "graph_open_failed\nSnapshot download timed out"))
  in
  check ~msg:"a failed graph open releases the loading state"
    (not failed.graph_loading);
  check ~msg:"the graph picker exposes graph lifecycle failures"
    (View_base.graph_picker_error_present_ failed);
  check_eq ~msg:"the graph picker retains the structured error code"
    (View_base.graph_picker_error_code failed)
    "graph_open_failed";
  check_eq ~msg:"the graph picker shows the actionable failure message"
    (View_base.graph_picker_error_message failed)
    "Snapshot download timed out"

let graphs_render_the_existing_catalog_and_modal_contract () =
  let application = App.create (ios_backend ()) in
  let local = graph "local" "Local graph" false false in
  let remote = graph "remote" "Remote graph" true true in
  let projection =
    {
      (empty_core_projection ()) with
      selected_graph_id = Some "local";
      graphs = [ local; remote ];
    }
  in
  start application;
  send application (Model.ApplyCoreSnapshot projection);
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.OpenSidebar;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let sidebar =
    descendant_with_identifier renderer root "sidebar.navigation"
  in
  let link =
    child_with_identifier renderer sidebar "link.sidebar.graphs"
  in
  dispatch application (Lui_protocol.Press link);
  flush application;
  let main = main_root renderer application in
  let screen = child_with_identifier renderer main "screen.graphs" in
  let refresh =
    child_with_identifier renderer screen "button.graphs.refresh"
  in
  let add = child_with_identifier renderer screen "button.graph-add" in
  let local_row = child_with_identifier renderer screen "graph.local" in
  let remote_row = child_with_identifier renderer screen "graph.remote" in
  let delete =
    descendant_with_identifier renderer screen "button.graph.delete.local"
  in
  let local_title_stack =
    descendant_with_node_kind renderer local_row Lui_protocol.Column
  in
  let delete_action =
    descendant_with_node_kind renderer delete Lui_protocol.MenuItem
  in
  check_eq ~msg:"graphs use the platform-native List container"
    (node renderer screen)
    (Some Lui_protocol.ListContainer);
  check_eq ~msg:"local graphs have a native section header"
    (node renderer
       (child_with_identifier renderer screen "heading.graphs.local"))
    (Some Lui_protocol.Heading);
  check_eq ~msg:"remote graphs have a native section header"
    (node renderer
       (child_with_identifier renderer screen "heading.graphs.remote"))
    (Some Lui_protocol.Heading);
  check_eq ~msg:"graph rows match main's content height"
    (property_int renderer local_row Lui_protocol.MinHeight)
    44;
  check_eq ~msg:"Refresh uses main's clockwise arrow"
    (property_string renderer refresh Lui_protocol.InlineIconName)
    "app:refresh";
  check_eq ~msg:"Add sync graph matches main's text-only row"
    (property_string renderer add Lui_protocol.InlineIconName)
    "<missing>";
  check_eq ~msg:"downloaded graphs use native list rows"
    (node renderer local_row)
    (Some Lui_protocol.ListItem);
  check_eq ~msg:"remote graphs use native list rows"
    (node renderer remote_row)
    (Some Lui_protocol.ListItem);
  check_eq ~msg:"Refresh is a native List row rather than a styled button"
    (node renderer refresh)
    (Some Lui_protocol.ListItem);
  check_eq ~msg:"Add sync graph is a native List row rather than a styled button"
    (node renderer add)
    (Some Lui_protocol.ListItem);
  check_eq ~msg:"local graph rows use main's database icon"
    (property_string renderer local_row Lui_protocol.InlineIconName)
    "app:graph-local";
  check_eq ~msg:"native graph rows do not add card padding"
    (property_int renderer local_row Lui_protocol.PaddingValue)
    (-1);
  check_eq ~msg:"native graph rows do not add a custom card radius"
    (property_int renderer local_row Lui_protocol.CornerRadius)
    (-1);
  check_eq ~msg:"native graph rows do not add a custom surface"
    (property_string renderer local_row Lui_protocol.BackgroundValue)
    "<missing>";
  check ~msg:"graphs keeps its refresh identifier" (refresh <> -1);
  check ~msg:"local graphs remain addressable" (local_row <> -1);
  check_eq ~msg:"preparing local graphs stay interactive like main"
    (descendant_enabled renderer screen "graph.local")
    (Some true);
  check ~msg:"remote graphs remain addressable" (remote_row <> -1);
  check ~msg:"local graphs expose deletion" (delete <> -1);
  check_eq ~msg:"the visible native Menu owns main's deletion identifier"
    (node renderer delete)
    (Some Lui_protocol.ContextMenu);
  check_eq ~msg:"local graph titles keep main's native HStack compression"
    (property_float renderer local_title_stack Lui_protocol.GrowValue)
    (-1.0);
  check_eq ~msg:"graph deletion does not add an icon absent from main"
    (property_string renderer delete_action Lui_protocol.InlineIconName)
    "<missing>";
  dispatch application (Lui_protocol.Press add);
  flush application;
  let application_root = Lui_app.root_node application in
  let form =
    descendant_with_identifier renderer application_root "form.graph-create"
  in
  let toolbar =
    descendant_with_identifier renderer application_root
      "toolbar.graph-create"
  in
  check ~msg:"graph fields use one native form group" (form <> -1);
  check ~msg:"graph actions use the navigation toolbar" (toolbar <> -1);
  if form <> -1 && toolbar <> -1 then begin
    check_eq ~msg:"graph fields retain their form presentation"
      (property_string renderer form Lui_protocol.StyleClass)
      "form";
    check_eq ~msg:"modal actions retain their navigation placement"
      (property_string renderer toolbar Lui_protocol.StyleClass)
      "navigation-actions";
    check ~msg:"add graph exposes the existing graph-name field"
      (descendant_with_identifier renderer form "field.graph-name" <> -1);
    check_eq ~msg:"Cancel uses the platform cancellation placement"
      (property_string renderer
         (descendant_with_identifier renderer toolbar
            "button.graph-add.cancel")
         Lui_protocol.StyleClass)
      "cancellation-action";
    check_eq ~msg:"Add uses the platform confirmation placement"
      (property_string renderer
         (descendant_with_identifier renderer toolbar
            "button.graph-add.confirm")
         Lui_protocol.StyleClass)
      "confirmation-action";
    check_eq ~msg:"Add remains disabled while the graph name is blank"
      (descendant_enabled renderer toolbar "button.graph-add.confirm")
      (Some false)
  end

let kotlin_graphs_use_a_compact_material_action_group () =
  let application = App.create (kotlin_backend ()) in
  let local = graph "local" "Local graph" false true in
  let remote = graph "remote" "Remote graph" false true in
  let projection =
    {
      (empty_core_projection ()) with
      selected_graph_id = Some "local";
      graph_name = Some "Local graph";
      graphs = [ local; remote ];
    }
  in
  start application;
  send application (Model.ApplyCoreSnapshot projection);
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.ShowGraphs;
  flush application;
  let renderer = Lui_app.runtime application in
  let screen =
    descendant_with_identifier renderer (main_root renderer application)
      "screen.graphs"
  in
  let actions =
    child_with_identifier renderer screen "row.graphs.actions"
  in
  let local_row = child_with_identifier renderer screen "graph.local" in
  check ~msg:"Android groups catalog actions into one compact Material row"
    (actions <> -1);
  if actions <> -1 then begin
    let refresh =
      descendant_with_identifier renderer actions "button.graphs.refresh"
    in
    let add =
      descendant_with_identifier renderer actions "button.graph-add"
    in
    check_eq ~msg:"Material actions use the compact spacing scale"
      (property_int renderer actions Lui_protocol.Gap)
      12;
    check_eq ~msg:"Material actions align with graph row content"
      (property_int renderer actions Lui_protocol.PaddingValue)
      16;
    check_eq ~msg:"Refresh is a Material button rather than a list row"
      (node renderer refresh)
      (Some Lui_protocol.Button);
    check_eq ~msg:"Refresh has lower emphasis than graph creation"
      (property_string renderer refresh Lui_protocol.VariantValue)
      "secondary";
    check_eq ~msg:"Refresh has an immediately recognizable sync icon"
      (property_string renderer refresh Lui_protocol.InlineIconName)
      "app:sync-status";
    check_eq ~msg:"Refresh shares the available action width"
      (property_float renderer refresh Lui_protocol.GrowValue)
      1.0;
    check_eq ~msg:"Add graph is a Material button rather than a list row"
      (node renderer add)
      (Some Lui_protocol.Button);
    check_eq ~msg:"Add graph is the clear primary action"
      (property_string renderer add Lui_protocol.VariantValue)
      "primary";
    check_eq ~msg:"Add graph uses the native Android add icon"
      (property_string renderer add Lui_protocol.InlineIconName)
      "app:add";
    check_eq ~msg:"Add graph shares the available action width"
      (property_float renderer add Lui_protocol.GrowValue)
      1.0;
    dispatch application (Lui_protocol.Press refresh);
    flush application;
    check_eq ~msg:"the Material Refresh button reaches the LG effect boundary"
      (App.model application).pending_effects
      [ Model.RefreshGraphsEffect 1 ]
  end;
  check_eq ~msg:"catalog entries remain native lazy list rows"
    (node renderer local_row)
    (Some Lui_protocol.ListItem)

let kotlin_add_graph_sheet_uses_one_material_form_layout () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application Model.OpenCreateGraph;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let sheet =
    descendant_with_identifier renderer root "sheet.graph-create"
  in
  let layout =
    descendant_with_identifier renderer sheet "layout.graph-create.sheet"
  in
  check_eq ~msg:"Kotlin bounds the Add graph Material sheet"
    (property_int renderer sheet Lui_protocol.HeightValue)
    480;
  check_eq ~msg:"Kotlin gives the backend one composed Add graph child"
    (List.length (children renderer sheet))
    1;
  check ~msg:"Kotlin owns one vertical Add graph layout" (layout <> -1);
  if layout <> -1 then begin
    let form =
      descendant_with_identifier renderer layout "form.graph-create"
    in
    let encryption =
      descendant_with_identifier renderer layout "toggle.graph-encryption"
    in
    check ~msg:"the form remains inside the composed layout" (form <> -1);
    check_eq ~msg:"the Material form fills the sheet width"
      (property_string renderer form Lui_protocol.CrossAlignment)
      "stretch";
    check_eq ~msg:"encryption uses a native Material switch row"
      (node renderer encryption)
      (Some Lui_protocol.SwitchControl);
    check ~msg:"the actions remain inside the composed layout"
      (descendant_with_identifier renderer layout "toolbar.graph-create"
      <> -1)
  end

let kotlin_add_graph_sheet_shows_creation_errors_inline () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application Model.OpenCreateGraph;
  send application (Model.ChangeNewGraphName "Broken graph");
  send application Model.SubmitCreateGraph;
  send application (Model.DequeueEffect 1);
  send application
    (Model.ResolveEffect (1, false, "Initial snapshot upload failed"));
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let error =
    descendant_with_identifier renderer root "text.graph-create.error"
  in
  check ~msg:"the Add graph sheet keeps its error visible" (error <> -1);
  check_eq ~msg:"the Add graph sheet explains why creation failed"
    (property_string renderer error Lui_protocol.TextValue)
    "Initial snapshot upload failed"

let graph_lifecycle_effects_disable_duplicate_actions () =
  let application = App.create (ios_backend ()) in
  let local = graph "local" "Local graph" false true in
  let remote = graph "remote" "Remote graph" true true in
  let projection =
    {
      (empty_core_projection ()) with
      graphs = [ local; remote ];
      selected_graph_id = None;
    }
  in
  start application;
  send application (Model.ApplyCoreSnapshot projection);
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.ShowGraphs;
  send application Model.RefreshGraphs;
  send application (Model.DequeueEffect 1);
  flush application;
  let renderer = Lui_app.runtime application in
  let screen =
    child_with_identifier renderer (main_root renderer application)
      "screen.graphs"
  in
  let refresh =
    child_with_identifier renderer screen "button.graphs.refresh"
  in
  let loading = child_with_identifier renderer screen "graphs.loading" in
  check_eq ~msg:"an in-flight refresh cannot be requested twice"
    (descendant_enabled renderer screen "button.graphs.refresh")
    (Some false);
  check ~msg:"refresh renders native progress feedback" (loading <> -1);
  check_eq
    ~msg:
      "ready encrypted graphs rely on main's lock icon without extra status \
       text"
    (descendant_with_identifier renderer screen "graph.status.remote")
    (-1);
  dispatch application (Lui_protocol.Press refresh);
  flush application;
  check_eq ~msg:"disabled refresh does not enqueue duplicate work"
    (App.model application).pending_effects [];
  send application (Model.RequestDeleteGraph "local");
  send application Model.ConfirmDeleteGraph;
  send application (Model.DequeueEffect 2);
  flush application;
  check_eq
    ~msg:
      "the local graph row disables every action while deletion is in flight"
    (descendant_enabled renderer (main_root renderer application)
       "graph.local")
    (Some false)

let empty_graph_picker_replaces_refresh_with_progress_while_loading () =
  let application = App.create (ios_backend ()) in
  start application;
  send application Model.RefreshGraphs;
  send application (Model.DequeueEffect 1);
  flush application;
  let renderer = Lui_app.runtime application in
  let picker =
    child_with_identifier renderer (main_root renderer application)
      "screen.graph-picker"
  in
  check ~msg:"an empty refreshing catalog shows progress"
    (child_with_identifier renderer picker "graphs.loading" <> -1);
  check_eq ~msg:"the empty picker hides refresh while it is running"
    (child_with_identifier renderer picker "button.graphs.refresh")
    (-1)

let graph_deletion_confirmation_names_the_local_graph () =
  let application = App.create (ios_backend ()) in
  let local = graph "local" "Local graph" false true in
  let projection =
    {
      (empty_core_projection ()) with
      graphs = [ local ];
      selected_graph_id = None;
    }
  in
  start application;
  send application (Model.ApplyCoreSnapshot projection);
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.ShowGraphs;
  send application (Model.RequestDeleteGraph "local");
  flush application;
  let renderer = Lui_app.runtime application in
  let warning =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "text.graph-delete-warning"
  in
  check ~msg:"the graph deletion warning has a stable identifier"
    (warning <> -1);
  check_eq ~msg:"the confirmation identifies the graph being deleted"
    (property_string renderer warning Lui_protocol.TextValue)
    "Are you sure you want to permanently delete the graph \"Local graph\" from Logseq?";
  send application Model.ConfirmDeleteGraph;
  send application (Model.DequeueEffect 1);
  send application
    (Model.ResolveEffect (1, false, "Could not delete graph"));
  flush application;
  let error =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "error.banner"
  in
  check
    ~msg:"a platform failure remains visible after the confirmation closes"
    (error <> -1);
  check_eq ~msg:"the visible error preserves the platform reason"
    (property_string renderer error Lui_protocol.TextValue)
    "Could not delete graph"

let kotlin_graph_deletion_uses_a_material_destructive_dialog () =
  let application = App.create (kotlin_backend ()) in
  let local = graph "local" "Local graph" false true in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graphs = [ local ];
         selected_graph_id = None;
       });
  send application (Model.ApplyLocalGraphIds [ "local" ]);
  send application Model.ShowGraphs;
  send application (Model.RequestDeleteGraph "local");
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let dialog =
    descendant_with_identifier renderer root "dialog.graph-delete"
  in
  let warning_icon =
    descendant_with_identifier renderer dialog "icon.graph-delete-warning"
  in
  let actions =
    descendant_with_identifier renderer dialog "toolbar.graph-delete"
  in
  let cancel =
    descendant_with_identifier renderer actions "button.graph-delete.cancel"
  in
  let confirm =
    descendant_with_identifier renderer actions "button.graph-delete.confirm"
  in
  check_eq
    ~msg:"the Material dialog has enough room without filling the screen"
    (property_int renderer dialog Lui_protocol.HeightValue)
    320;
  check_eq ~msg:"the irreversible warning uses a Material icon"
    (property_string renderer warning_icon Lui_protocol.IconName)
    "app:warning";
  check_eq ~msg:"dialog actions follow the Material horizontal action row"
    (property_string renderer actions Lui_protocol.OrientationValue)
    "horizontal";
  check_eq ~msg:"Cancel remains the quiet action"
    (property_string renderer cancel Lui_protocol.VariantValue)
    "ghost";
  check_eq ~msg:"Delete is visually marked as destructive"
    (property_string renderer confirm Lui_protocol.VariantValue)
    "destructive"

let search_lifecycle_keeps_query_owned_by_the_lg_model () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  flush application;
  let renderer = Lui_app.runtime application in
  let chrome = native_bottom_chrome renderer application in
  let search_button =
    descendant_with_identifier renderer chrome "button.search"
  in
  check_eq ~msg:"search keeps the main-branch accessibility identifier"
    (property_string renderer search_button
       Lui_protocol.AccessibilityIdentifier)
    "button.search";
  dispatch application (Lui_protocol.Press search_button);
  flush application;
  check ~msg:"search presentation is model-owned"
    (App.model application).search_open;
  let search_root = main_root renderer application in
  let search_extension =
    extension_node application "native-search-presentation"
  in
  let search_panel =
    child_with_identifier renderer search_root "screen.search"
  in
  check_eq ~msg:"search presentation keeps its screen identifier"
    (property_string renderer search_panel
       Lui_protocol.AccessibilityIdentifier)
    "screen.search";
  check_eq ~msg:"LG does not duplicate the platform search field"
    (descendant_with_identifier renderer search_panel "field.search")
    (-1);
  check_eq ~msg:"full-screen search replaces the journal list"
    (descendant_with_identifier renderer search_root "list.outliner")
    (-1);
  check_eq ~msg:"full-screen search hides the journal header controls"
    (child_with_identifier renderer search_root "button.sidebar")
    (-1);
  check_eq ~msg:"full-screen search owns the complete visible surface"
    (child_with_identifier renderer search_root "button.connection")
    (-1);
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( search_extension,
         "native-search-presentation",
         "query-changed",
         Lui_protocol.String_map.singleton "query"
           (Lui_protocol.StringValue "project alpha") ));
  flush application;
  check_eq ~msg:"the query is stored in LG state"
    (App.model application).search_query "project alpha";
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( search_extension,
         "native-search-presentation",
         "dismiss",
         Lui_protocol.String_map.empty ));
  flush application;
  check ~msg:"close removes the search presentation"
    (not (App.model application).search_open);
  check_eq ~msg:"close clears transient search input"
    (App.model application).search_query "";
  check_eq ~msg:"the retained search subtree is disposed"
    (child_with_identifier renderer (main_root renderer application)
       "screen.search")
    (-1)

let bottom_chrome_presentation_is_mutually_exclusive () =
  let journal =
    {
      (Model.initial ()) with
      Model.selected_graph = Some "Work";
      selected_graph_id = Some "graph-a";
    }
  in
  let expanded = { journal with Model.composer_expanded = true } in
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Draft";
      caret_utf16_offset = 5;
    }
  in
  check_eq ~msg:"the journal root defaults to Capture and Search"
    (View_base.bottom_chrome_presentation journal)
    "capture-and-search";
  check_eq ~msg:"expanded Capture replaces Search"
    (View_base.bottom_chrome_presentation expanded)
    "expanded-composer";
  check_eq ~msg:"the editor replaces an expanded composer"
    (View_base.bottom_chrome_presentation
       { expanded with Model.outliner_editing = Some editing })
    "outliner-editor";
  check_eq ~msg:"selection has highest priority"
    (View_base.bottom_chrome_presentation
       {
         expanded with
         Model.outliner_editing = Some editing;
         outliner_selected_block_ids = [ "block-a" ];
       })
    "outliner-selection";
  check_eq ~msg:"node pages keep Capture visible like main"
    (View_base.bottom_chrome_presentation
       {
         journal with
         Model.app_navigation_path = [ Model.NodeRoute "node-a" ];
       })
    "capture-and-search"

let composer_matches_the_main_branch_expand_draft_and_send_contract () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let chrome = native_bottom_chrome renderer application in
  let composer =
    descendant_with_identifier renderer chrome "surface.composer.root"
  in
  let placement =
    descendant_with_identifier renderer chrome "row.bottom.capture"
  in
  let search =
    descendant_with_identifier renderer chrome "button.search"
  in
  let collapsed =
    descendant_with_identifier renderer chrome "button.composer.expand"
  in
  check_eq
    ~msg:"the composer keeps intrinsic height inside a bottom overlay"
    (node renderer composer)
    (Some Lui_protocol.Box);
  check_eq ~msg:"Capture floats above the Outliner like main"
    (extension_property application navigation
       "bottom-occupies-layout-space")
    (Some (Lui_protocol.BoolValue false));
  check_eq
    ~msg:
      "the collapsed bottom row fills the viewport for symmetric edge insets"
    (property_float renderer placement Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"collapsed search uses the main branch icon control"
    (property_string renderer search Lui_protocol.InlineIconName)
    "app:search";
  check_eq ~msg:"search keeps semantic ghost styling"
    (property_string renderer search Lui_protocol.VariantValue)
    "ghost";
  check_eq ~msg:"collapsed capture keeps its automation identifier"
    (property_string renderer collapsed Lui_protocol.AccessibilityIdentifier)
    "button.composer.expand";
  send application Model.ExpandComposer;
  flush application;
  check ~msg:"capture expands from LG-owned state"
    (App.model application).composer_expanded;
  check_eq ~msg:"expanded Capture replaces Search"
    (descendant_with_identifier renderer
       (native_bottom_chrome renderer application)
       "button.search")
    (-1);
  let expanded_chrome = native_bottom_chrome renderer application in
  let expanded_row =
    descendant_with_identifier renderer expanded_chrome
      "row.composer.placement"
  in
  let expanded_composer =
    descendant_with_identifier renderer expanded_chrome
      "surface.composer.root"
  in
  let expanded =
    parent_with_child_identifier renderer expanded_composer "field.composer"
  in
  let field =
    descendant_with_identifier renderer expanded "field.composer"
  in
  let controls =
    descendant_with_identifier renderer expanded "row.composer.controls"
  in
  let top_spacer =
    descendant_with_identifier renderer expanded "spacer.composer.top"
  in
  let field_controls_spacer =
    descendant_with_identifier renderer expanded
      "spacer.composer.field-controls"
  in
  let control_children = children renderer controls in
  let attachment =
    descendant_with_identifier renderer controls "button.attachment"
  in
  let task_status_node =
    descendant_with_identifier renderer controls "button.task-status"
  in
  let control_spacer =
    descendant_with_identifier renderer controls "spacer.composer.controls"
  in
  let send_button =
    descendant_with_identifier renderer controls "button.send"
  in
  check_eq
    ~msg:"expanded Capture keeps intrinsic bottom-overlay height"
    (property_string renderer expanded_row Lui_protocol.CrossAlignment)
    "center";
  check_eq
    ~msg:"expanded Capture does not stretch vertically inside its column"
    (property_float renderer expanded_row Lui_protocol.GrowValue)
    (-1.0);
  check_eq ~msg:"expanded capture keeps its field identifier"
    (property_string renderer field Lui_protocol.AccessibilityIdentifier)
    "field.composer";
  check_eq ~msg:"expanded capture keeps its stable surface identifier"
    (property_string renderer expanded_composer
       Lui_protocol.AccessibilityIdentifier)
    "surface.composer.root";
  check_eq ~msg:"the composer adds main's six-point top inset delta"
    (property_int renderer top_spacer Lui_protocol.HeightValue)
    6;
  check_eq ~msg:"the field and controls retain main's separation"
    (property_int renderer field_controls_spacer Lui_protocol.HeightValue)
    8;
  check_eq ~msg:"attachment keeps its automation identifier"
    (property_string renderer attachment Lui_protocol.AccessibilityIdentifier)
    "button.attachment";
  check_eq ~msg:"task status keeps its automation identifier"
    (property_string renderer task_status_node
       Lui_protocol.AccessibilityIdentifier)
    "button.task-status";
  check_eq
    ~msg:"composer controls keep a fixed footer height as the draft grows"
    (property_int renderer controls Lui_protocol.HeightValue)
    44;
  check_eq ~msg:"main's controls include a flexible trailing spacer"
    (List.length control_children) 4;
  check_eq ~msg:"the composer spacer remains directly testable"
    (property_string renderer control_spacer
       Lui_protocol.AccessibilityIdentifier)
    "spacer.composer.controls";
  check_eq ~msg:"the unset task status uses main's circular outline"
    (property_string renderer task_status_node Lui_protocol.InlineIconName)
    "app:task-todo";
  check_eq ~msg:"a flexible spacer keeps Send at the trailing edge"
    (property_float renderer control_spacer Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"send keeps its automation identifier"
    (property_string renderer send_button Lui_protocol.AccessibilityIdentifier)
    "button.send";
  check_eq ~msg:"send uses main's upward arrow"
    (property_string renderer send_button Lui_protocol.InlineIconName)
    "app:arrow-up";
  check_eq
    ~msg:"an empty draft lets native disabled styling dim main's black fill"
    (property_string renderer send_button Lui_protocol.BackgroundValue)
    "black";
  check_eq ~msg:"send arrow contrasts with the filled surface"
    (property_string renderer send_button Lui_protocol.ForegroundValue)
    "white";
  check_eq ~msg:"send uses a compact circular surface"
    (property_int renderer send_button Lui_protocol.WidthValue)
    36;
  check_eq ~msg:"send uses a compact circular surface"
    (property_int renderer send_button Lui_protocol.HeightValue)
    36;
  check_eq ~msg:"send remains circular"
    (property_int renderer send_button Lui_protocol.CornerRadius)
    18;
  send application (Model.ChangeComposerDraft "  Project note  ");
  flush application;
  let updated_chrome = native_bottom_chrome renderer application in
  let updated_send_button =
    descendant_with_identifier renderer updated_chrome "button.send"
  in
  check_eq ~msg:"a nonempty draft enables main's black send fill"
    (property_string renderer updated_send_button
       Lui_protocol.BackgroundValue)
    "black";
  check_eq ~msg:"draft text is model-owned without eager trimming"
    (App.model application).composer_draft "  Project note  ";
  send application Model.SendComposer;
  flush application;
  check_eq ~msg:"successful send clears the draft"
    (App.model application).composer_draft "";
  check_eq ~msg:"send clears persisted text before publishing capture"
    (App.model application).pending_effects
    [
      Model.PersistComposerDraftEffect (2, "");
      Model.SendCaptureEffect (3, "Project note");
    ];
  check_eq ~msg:"draft persistence and capture receive stable identifiers"
    (App.model application).next_effect_id 4;
  check ~msg:"send keeps the composer expanded like main"
    (App.model application).composer_expanded;
  let updated_navigation =
    extension_node application "native-navigation-stack"
  in
  check_eq ~msg:"the native host owns the outside-tap dismissal layer"
    (extension_property application updated_navigation
       "composer-dismissal-enabled")
    (Some (Lui_protocol.BoolValue true));
  send application Model.DismissComposer;
  flush application;
  check ~msg:"the native outside-tap layer dismisses through LG state"
    (not (App.model application).composer_expanded)

let ios_capture_and_search_match_main_native_metrics () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  flush application;
  let renderer = Lui_app.runtime application in
  let chrome = native_bottom_chrome renderer application in
  let row =
    descendant_with_identifier renderer chrome "row.bottom.capture"
  in
  let search =
    descendant_with_identifier renderer chrome "button.search"
  in
  let capture =
    descendant_with_identifier renderer chrome "button.composer.expand"
  in
  let top_inset =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "spacer.outliner.top"
  in
  let capture_glass =
    descendant_with_extension renderer application chrome "liquid-glass"
  in
  check_eq ~msg:"Capture and Search keep main's ten-point separation"
    (property_int renderer row Lui_protocol.Gap)
    10;
  check_eq ~msg:"Search keeps main's native 58-point hit target"
    (property_int renderer search Lui_protocol.WidthValue)
    58;
  check_eq ~msg:"Search keeps main's native 58-point hit target"
    (property_int renderer search Lui_protocol.HeightValue)
    58;
  check_eq ~msg:"Search uses the native 24-point icon size policy"
    (property_string renderer search Lui_protocol.SizeValue)
    "icon";
  check_eq ~msg:"iOS keeps main's compact native-navigation inset"
    (property_int renderer top_inset Lui_protocol.HeightValue)
    16;
  check_eq ~msg:"Capture insets its label without moving its glass surface."
    (property_int renderer capture Lui_protocol.PaddingHorizontal)
    30;
  check_eq
    ~msg:"Liquid Glass remains independent from app content spacing"
    (extension_property application capture_glass "leading-inset")
    None

let composer_dismissal_preserves_an_unsent_draft () =
  let expanded = Model.update (Model.initial ()) Model.ExpandComposer in
  let drafted =
    Model.update expanded (Model.ChangeComposerDraft "Later")
  in
  let dismissed = Model.update drafted Model.DismissComposer in
  let empty_send = Model.update dismissed Model.SendComposer in
  check ~msg:"dismiss collapses composer state"
    (not dismissed.composer_expanded);
  check_eq ~msg:"dismiss preserves the persisted draft"
    dismissed.composer_draft "Later";
  check_eq ~msg:"a preserved non-empty draft can still be submitted"
    empty_send.pending_effects
    [
      Model.PersistComposerDraftEffect (2, "");
      Model.SendCaptureEffect (3, "Later");
    ]

let pending_outliner_text_keeps_the_latest_optimistic_edit () =
  let latest =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Latest local text";
      caret_utf16_offset = 17;
    }
  in
  let stale =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Stale core text";
      caret_utf16_offset = 15;
    }
  in
  let projection =
    {
      (empty_core_projection ()) with
      Model.projection_outliner_editing = Some stale;
      projection_outliner_autocomplete_candidates = [
        { Model.candidate_index = 0; candidate_label = "Old result";
          candidate_value = "old-result" } ];
    }
  in
  let pending =
    {
      (Model.initial ()) with
      Model.outliner_editing = Some latest;
      pending_effects =
        [
          Model.ChangeOutlinerTextEffect (1, "block-a", "Latest local text", 17);
        ];
    }
  in
  let preserved =
    Model.update pending (Model.ApplyCoreSnapshot projection)
  in
  let settled =
    Model.update
      { pending with Model.pending_effects = [] }
      (Model.ApplyCoreSnapshot projection)
  in
  check_eq ~msg:"an older core response cannot overwrite queued typing"
    preserved.outliner_editing (Some latest);
  check_eq ~msg:"an older autocomplete response cannot publish stale candidates"
    preserved.outliner_autocomplete_candidates [];
  check_eq ~msg:"the authoritative value applies after local typing settles"
    settled.outliner_editing (Some stale)

let outliner_typing_removes_stale_autocomplete_candidates () =
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Draft #";
      caret_utf16_offset = 7;
    }
  in
  let autocomplete =
    {
      Model.autocomplete_kind = Model.TagAutocomplete;
      autocomplete_query = "";
    }
  in
  let candidate =
    {
      Model.candidate_index = 0;
      candidate_label = "Card";
      candidate_value = "tag-card";
    }
  in
  let current =
    {
      (Model.initial ()) with
      Model.outliner_editing = Some editing;
      outliner_autocomplete = Some autocomplete;
      outliner_autocomplete_candidates = [ candidate ];
    }
  in
  let updated =
    Model.update current
      (Model.ChangeOutlinerText ("block-a", "Draft #Project", 14))
  in
  check_eq ~msg:"typing hides candidates produced for the previous query"
    updated.outliner_autocomplete_candidates [];
  check_eq
    ~msg:
      "the authoritative core query still runs after stale candidates \
       disappear"
    updated.pending_effects
    [
      Model.ChangeOutlinerTextEffect (1, "block-a", "Draft #Project", 14);
    ]

let autocomplete_selection_waits_for_pending_text_to_settle () =
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Draft #Project";
      caret_utf16_offset = 14;
    }
  in
  let change =
    Model.ChangeOutlinerTextEffect (1, "block-a", "Draft #Project", 14)
  in
  let base =
    { (Model.initial ()) with Model.outliner_editing = Some editing }
  in
  let pending =
    { base with Model.pending_effects = [ change ]; next_effect_id = 2 }
  in
  let in_flight =
    { base with Model.in_flight_effects = [ change ]; next_effect_id = 2 }
  in
  let settled = { base with Model.next_effect_id = 2 } in
  check_eq ~msg:"completion queues behind pending typing"
    (Model.update pending
       (Model.ChooseOutlinerAutocomplete "tag-project"))
      .pending_effects
    [ change; Model.ChooseOutlinerAutocompleteEffect (2, "tag-project") ];
  let updated =
    Model.update in_flight
      (Model.ChooseOutlinerAutocomplete "tag-project")
  in
  check_eq ~msg:"in-flight typing retains ownership" updated.in_flight_effects
    [ change ];
  check_eq ~msg:"completion waits behind in-flight typing"
    updated.pending_effects
    [ Model.ChooseOutlinerAutocompleteEffect (2, "tag-project") ];
  check_eq
    ~msg:"the refreshed candidate remains selectable after typing settles"
    (Model.update settled
       (Model.ChooseOutlinerAutocomplete "tag-project"))
      .pending_effects
    [ Model.ChooseOutlinerAutocompleteEffect (2, "tag-project") ]

let hide_keyboard_optimistically_finishes_outliner_editing () =
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Latest local text";
      caret_utf16_offset = 17;
    }
  in
  let autocomplete =
    {
      Model.autocomplete_kind = Model.NodeAutocomplete;
      autocomplete_query = "Latest";
    }
  in
  let current =
    {
      (Model.initial ()) with
      Model.outliner_editing = Some editing;
      outliner_autocomplete = Some autocomplete;
      outliner_autocomplete_candidates = [];
    }
  in
  let updated =
    Model.update current
      (Model.PerformOutlinerToolbarAction "hideKeyboard")
  in
  check_eq ~msg:"hide keyboard removes the inline editor immediately"
    updated.outliner_editing None;
  check_eq ~msg:"hide keyboard removes autocomplete with the editor"
    updated.outliner_autocomplete None;
  check_eq ~msg:"core still owns committing the final editor value"
    updated.pending_effects
    [ Model.OutlinerToolbarEffect (1, "hideKeyboard") ]

let outliner_return_handoff_retains_one_native_editor_node () =
  let application = App.create (ios_backend ()) in
  let first_row =
    journal_outline_row "block-a" "journal" "First" "Aug 28th, 2026"
      20260828 0
  in
  let second_row =
    journal_outline_row "block-b" "journal" "" "Aug 28th, 2026" 20260828 0
  in
  let first_editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "First";
      caret_utf16_offset = 5;
    }
  in
  let second_editing =
    {
      Model.editing_uuid = "block-b";
      editing_title = "";
      caret_utf16_offset = 0;
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       (Some first_editing) None [] [] [ first_row ] false []);
  flush application;
  let first_editor = extension_node application "outliner-editor" in
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       (Some second_editing) None [] [] [ first_row; second_row ] false []);
  flush application;
  check_eq ~msg:"Return moves one retained editor between keyed rows"
    (extension_node application "outliner-editor")
    first_editor

let composer_draft_restore_focus_and_dismissal_are_owned_by_lg () =
  let restored =
    Model.update (Model.initial ())
      (Model.ApplyComposerDraft "稍后处理\nsecond line")
  in
  let expanded = Model.update restored Model.ExpandComposer in
  let drafted =
    Model.update expanded (Model.ChangeComposerDraft "Later")
  in
  let dismissed = Model.update drafted Model.DismissComposer in
  check_eq ~msg:"the persisted draft is restored through a typed host update"
    restored.composer_draft "稍后处理\nsecond line";
  check ~msg:"expanding requests native focus on the mounted composer field"
    expanded.composer_autofocus;
  check ~msg:"typing consumes the edge-triggered autofocus request"
    (not drafted.composer_autofocus);
  check_eq ~msg:"draft persistence crosses one coalescible platform boundary"
    drafted.pending_effects
    [ Model.PersistComposerDraftEffect (1, "Later") ];
  check ~msg:"dismissal releases composer focus"
    (not dismissed.composer_autofocus);
  check_eq ~msg:"dismissal keeps the persisted capture text"
    dismissed.composer_draft "Later"

let composer_refocus_always_emits_an_autofocus_edge () =
  let expanded =
    Model.update (Model.initial ()) Model.ExpandComposer
  in
  (* the armed flag reads true but the host field may be unfocused; every
     FocusComposer must still flip the prop so the edge reaches the host *)
  let first = Model.update expanded Model.FocusComposer in
  let second = Model.update first Model.FocusComposer in
  check ~msg:"expanding arms the autofocus edge" expanded.composer_autofocus;
  check ~msg:"a refocus request while armed flips the flag"
    (not first.composer_autofocus);
  check ~msg:"the next refocus request flips it back" second.composer_autofocus

let composer_renders_autofocus_and_native_outside_dismissal () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  send application Model.ExpandComposer;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let navigation = extension_node application "native-navigation-stack" in
  let field =
    descendant_with_identifier renderer root "field.composer"
  in
  let dismissal_enabled =
    extension_property application navigation "composer-dismissal-enabled"
  in
  check ~msg:"the expanded field receives the native autofocus edge"
    (property_bool renderer field Lui_protocol.Autofocus);
  check_eq ~msg:"expanded capture enables the native dismissal layer"
    dismissal_enabled (Some (Lui_protocol.BoolValue true));
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-navigation-stack",
         "dismiss-composer",
         Lui_protocol.String_map.empty ));
  flush application;
  check ~msg:"the native outside tap collapses the composer"
    (not (App.model application).composer_expanded)

let kotlin_composer_matches_ios_chrome () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "work";
         graph_name = Some "Work";
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let chrome = List.nth (children renderer navigation) 1 in
  let placement =
    descendant_with_identifier renderer chrome "row.bottom.capture"
  in
  let composer =
    descendant_with_identifier renderer chrome "surface.composer.root"
  in
  let collapsed = List.nth (children renderer composer) 0 in
  check_eq ~msg:"the Android capture row fills its dock slot like iOS"
    (property_float renderer placement Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"collapsed Capture is a ghost like iOS"
    (property_string renderer collapsed Lui_protocol.VariantValue)
    "ghost";
  check_eq ~msg:"collapsed Capture uses the iOS glass surface"
    (property_string renderer collapsed Lui_protocol.BackgroundValue)
    "glass";
  check_eq ~msg:"collapsed Capture keeps the iOS pill shape"
    (property_int renderer collapsed Lui_protocol.CornerRadius)
    999;
  check_eq ~msg:"collapsed Capture fills the available dock width"
    (property_float renderer collapsed Lui_protocol.GrowValue)
    1.0;
  dispatch application (Lui_protocol.Press collapsed);
  flush application;
  let expanded_composer =
    descendant_with_identifier renderer chrome "surface.composer.root"
  in
  let expanded = List.nth (children renderer expanded_composer) 0 in
  let send_button =
    descendant_with_identifier renderer expanded "button.send"
  in
  check_eq ~msg:"expanded Capture uses the iOS glass surface"
    (property_string renderer expanded Lui_protocol.BackgroundValue)
    "glass";
  check_eq ~msg:"expanded Capture uses the iOS capsule shape"
    (property_int renderer expanded Lui_protocol.CornerRadius)
    24;
  check_eq ~msg:"Send matches the 36-point iOS circle"
    (property_int renderer send_button Lui_protocol.WidthValue)
    36;
  check_eq ~msg:"Send is a black iOS-style circle"
    (property_string renderer send_button Lui_protocol.BackgroundValue)
    "black"

let kotlin_sidebar_uses_compact_material_drawer_metrics () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "work";
         graph_name = Some "Work";
       });
  send application Model.OpenSidebar;
  flush application;
  let renderer = Lui_app.runtime application in
  let drawer = application_shell_root renderer application in
  let sidebar =
    descendant_with_identifier renderer drawer "sidebar.navigation"
  in
  let top_spacer = List.nth (children renderer sidebar) 0 in
  check_eq ~msg:"the Android drawer leaves meaningful content visible"
    (property_int renderer drawer Lui_protocol.WidthValue)
    320;
  check_eq ~msg:"SafeArea already owns Android system-bar spacing"
    (property_int renderer top_spacer Lui_protocol.HeightValue)
    8

let composer_attachment_selection_is_owned_by_lg () =
  let opened =
    Model.update (Model.initial ()) Model.OpenAttachmentPicker
  in
  let selected = Model.update opened (Model.ChooseAttachment "photos") in
  check ~msg:"the composer attachment menu is model-owned"
    opened.attachment_picker_open;
  check ~msg:"choosing an attachment closes the menu"
    (not selected.attachment_picker_open);
  check_eq ~msg:"the chosen system service crosses one typed boundary"
    selected.pending_effects
    [ Model.PresentAttachmentEffect (1, "photos") ];
  check_eq ~msg:"the native bridge preserves the attachment service kind"
    (Native_bridge.encode_effect
       (Model.PresentAttachmentEffect (7, "files")))
    "{\"id\":7,\"kind\":\"present-attachment\",\"text\":\"files\"}"

let composer_attachment_picker_owns_each_presented_action () =
  List.iter (fun service ->
    let application = App.create (ios_backend ()) in
    start application;
    send application (Model.SelectGraph "Work");
    send application Model.ExpandComposer;
    flush application;
    let renderer = Lui_app.runtime application in
    let root = Lui_app.root_node application in
    let identifier = "button.attachment." ^ service in
    check_eq ~msg:"closed attachment pickers do not leave native menu actions mounted"
      (descendant_with_identifier renderer root identifier) (-1);
    let trigger = descendant_with_identifier renderer root "button.attachment" in
    dispatch application (Lui_protocol.Press trigger);
    flush application;
    let action = descendant_with_identifier renderer root identifier in
    check ~msg:"the attachment trigger presents each action" (action <> -1);
    dispatch application (Lui_protocol.Press action);
    flush application;
    check_eq ~msg:"selecting an attachment dismisses the picker"
      (descendant_with_identifier renderer root identifier) (-1);
    check_eq ~msg:"the selected service reaches native presentation exactly once"
      (App.model application).pending_effects
      [Model.PresentAttachmentEffect (1, service)])
    ["files"; "camera"; "photos"; "audio"]

let composer_attachment_menu_preserves_main_actions () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  send application Model.ExpandComposer;
  send application Model.OpenAttachmentPicker;
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let files =
    descendant_with_identifier renderer navigation "button.attachment.files"
  in
  let camera =
    descendant_with_identifier renderer navigation "button.attachment.camera"
  in
  let photos =
    descendant_with_identifier renderer navigation "button.attachment.photos"
  in
  let audio =
    descendant_with_identifier renderer navigation "button.attachment.audio"
  in
  List.iter
    (fun action ->
       check_eq ~msg:"attachment actions are native menu items"
         (node renderer action) (Some Lui_protocol.MenuItem))
    [ files; camera; photos; audio ];
  check_eq ~msg:"main uses the singular File action"
    (property_string renderer files Lui_protocol.TextValue)
    "File";
  check_eq ~msg:"main uses the singular Photo action"
    (property_string renderer photos Lui_protocol.TextValue)
    "Photo";
  check_eq ~msg:"File keeps main's menu icon"
    (property_string renderer files Lui_protocol.InlineIconName)
    "app:toolbar-attachment";
  check_eq ~msg:"Camera keeps main's menu icon"
    (property_string renderer camera Lui_protocol.InlineIconName)
    "app:toolbar-camera";
  check_eq ~msg:"Photo keeps main's menu icon"
    (property_string renderer photos Lui_protocol.InlineIconName)
    "app:composer-photo";
  check_eq ~msg:"Audio recording keeps main's menu icon"
    (property_string renderer audio Lui_protocol.InlineIconName)
    "app:toolbar-audio";
  check ~msg:"the attachment menu includes files" (files <> -1);
  check ~msg:"the attachment menu includes camera" (camera <> -1);
  check ~msg:"the attachment menu includes photos" (photos <> -1);
  check ~msg:"the attachment menu includes audio recording" (audio <> -1)

let composer_task_status_selection_and_send_are_owned_by_lg () =
  let todo =
    task_status "todo" (Some "logseq.property/status.todo") "Todo"
      (Some "tabler-icon") (Some "Todo") None
  in
  let projected =
    Model.update (Model.initial ())
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           task_statuses = [ todo ];
         })
  in
  let opened = Model.update projected Model.OpenTaskStatusPicker in
  let selected = Model.update opened (Model.ChooseTaskStatus "todo") in
  let drafted =
    Model.update selected (Model.ChangeComposerDraft " Follow up ")
  in
  let sent = Model.update drafted Model.SendComposer in
  let cleared = Model.update selected Model.ClearTaskStatus in
  check_eq ~msg:"core task statuses enter LG state before fallbacks"
    (List.nth projected.task_statuses 0) todo;
  check ~msg:"the task status menu is model-owned"
    opened.task_status_picker_open;
  check_eq ~msg:"the chosen status remains selected for subsequent captures"
    selected.selected_task_status (Some todo);
  check ~msg:"choosing a status closes the menu"
    (not selected.task_status_picker_open);
  check_eq ~msg:"task capture preserves its full semantic status"
    sent.pending_effects
    [
      Model.PersistComposerDraftEffect (2, "");
      Model.SendTaskEffect (3, "Follow up", todo);
    ];
  check_eq ~msg:"sending a task preserves the selected status like main"
    sent.selected_task_status (Some todo);
  check_eq ~msg:"the status can be cleared without changing the draft"
    cleared.selected_task_status None

let composer_task_status_menu_preserves_main_actions () =
  let application = App.create (ios_backend ()) in
  let todo =
    task_status "todo" (Some "logseq.property/status.todo") "Todo"
      (Some "tabler-icon") (Some "Todo") None
  in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "test-graph";
         task_statuses = [ todo ];
       });
  send application Model.ExpandComposer;
  send application Model.OpenTaskStatusPicker;
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let option =
    descendant_with_identifier renderer navigation
      "button.task-status.option.todo"
  in
  check ~msg:"the task status menu renders Todo" (option <> -1);
  check_eq ~msg:"the native task status action preserves its label"
    (property_string renderer option Lui_protocol.TextValue)
    "Todo";
  check_eq ~msg:"the task status menu preserves main's semantic icon"
    (property_string renderer option Lui_protocol.InlineIconName)
    "app:task-todo";
  check_eq ~msg:"the task status menu preserves main's semantic color"
    (property_string renderer option Lui_protocol.ForegroundValue)
    "task-todo"

let task_capture_has_a_stable_native_effect_payload () =
  let todo =
    task_status "todo" (Some "logseq.property/status.todo") "Todo"
      (Some "tabler-icon") (Some "Todo") None
  in
  check_eq ~msg:"the native task payload preserves semantic status metadata"
    (Native_bridge.encode_effect
       (Model.SendTaskEffect (8, "Follow up", todo)))
    "{\"id\":8,\"kind\":\"send-task\",\"text\":\"Follow up\",\"metadata\":\"{\\\"uuid\\\":\\\"todo\\\",\\\"ident\\\":\\\"logseq.property/status.todo\\\",\\\"title\\\":\\\"Todo\\\",\\\"iconType\\\":\\\"tabler-icon\\\",\\\"iconId\\\":\\\"Todo\\\",\\\"iconColor\\\":null}\"}"

let task_status_choices_preserve_main_built_in_fallbacks () =
  let custom =
    task_status "waiting" (Some "user.status/waiting") "Waiting"
      (Some "tabler-icon") (Some "clock") None
  in
  let projected =
    Model.update (Model.initial ())
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           task_statuses = [ custom ];
         })
  in
  check_eq
    ~msg:"the composer offers main's built-in choices before remote refresh"
    (List.map
       (fun (status : Model.task_status) -> status.Model.title)
       (Model.built_in_task_statuses ()))
    [ "Backlog"; "Todo"; "Doing"; "In Review"; "Done"; "Canceled" ];
  check_eq ~msg:"graph-specific statuses remain first"
    (List.nth projected.task_statuses 0) custom;
  check_eq ~msg:"built-in fallbacks are appended after custom statuses"
    (List.length projected.task_statuses) 7

let native_bridge_renders_restored_authentication_in_the_first_patch () =
  let patch = Native_bridge.initialize 3 1 1 in
  check ~msg:"signed-out initialization renders authentication immediately"
    (contains "screen.authentication" patch);
  check ~msg:"signed-out initialization never constructs the journals tree"
    (not (contains "journals.graph-loaded" patch));
  check ~msg:"signed-out initialization excludes main navigation controls"
    (not (contains "button.search" patch))

let native_bridge_selects_the_kotlin_host_profile () =
  check ~msg:"Kotlin Android uses the retained Kotlin backend profile"
    (Native_bridge.host_kind 4 = Lui_protocol.KotlinHost);
  check ~msg:"Apple hosts keep the SwiftUI profile"
    (Native_bridge.host_kind 2 = Lui_protocol.SwiftUIHost);
  let patch = Native_bridge.initialize 3 4 1 in
  check ~msg:"Kotlin renders the shared authentication screen"
    (contains "screen.authentication" patch);
  check ~msg:"Kotlin does not receive SwiftUI-only viewport properties"
    (not (contains "container-relative-frame" patch));
  let patch = Native_bridge.initialize 3 4 3 in
  check ~msg:"signed-in Kotlin renders the Material graph picker controls"
    (contains "menu-trigger" patch);
  check
    ~msg:"signed-in Kotlin excludes every SwiftUI-only viewport property"
    (not (contains "container-relative-frame" patch));
  check ~msg:"signed-in Kotlin excludes unsupported list-item icon placement"
    (not (contains "icon-placement" patch));
  check ~msg:"signed-in Kotlin excludes unsupported list-item heading roles"
    (not (contains "navigation-heading" patch));
  check ~msg:"signed-in Kotlin excludes unsupported list-item navigation roles"
    (not (contains "\"navigation\"" patch));
  let patch =
    Native_bridge.flush_action
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           graph_name = Some "Work";
           selected_graph_id = Some "graph-a";
           graphs = [ graph "graph-a" "Work" false true ];
         })
  in
  check
    ~msg:"graph restoration excludes unsupported list-item icon placement"
    (not (contains "icon-placement" patch));
  check
    ~msg:"graph restoration excludes unsupported list-item heading roles"
    (not (contains "navigation-heading" patch));
  check
    ~msg:"graph restoration excludes unsupported list-item navigation roles"
    (not (contains "\"navigation\"" patch));
  ignore (Native_bridge.dispose ())

let kotlin_search_presentation_owns_an_opaque_background () =
  ignore (Native_bridge.initialize 3 4 3);
  ignore
    (Native_bridge.flush_action
       (Model.ApplyCoreSnapshot
          {
            (empty_core_projection ()) with
            graph_name = Some "Work";
            selected_graph_id = Some "graph-a";
            graphs = [ graph "graph-a" "Work" false true ];
          }));
  let patch = Native_bridge.flush_action Model.OpenSearch in
  check ~msg:"opening Kotlin search mounts the search screen"
    (contains "screen.search" patch);
  check ~msg:"Kotlin search covers the retained journal surface"
    (contains "\"property\":\"background\",\"value\":\"background\"" patch);
  ignore (Native_bridge.dispose ());
  ignore (Native_bridge.initialize 2 2 3);
  ignore
    (Native_bridge.flush_action
       (Model.ApplyCoreSnapshot
          {
            (empty_core_projection ()) with
            graph_name = Some "Work";
            selected_graph_id = Some "graph-a";
            graphs = [ graph "graph-a" "Work" false true ];
          }));
  let patch = Native_bridge.flush_action Model.OpenSearch in
  check ~msg:"the Kotlin-only backdrop does not alter SwiftUI search"
    (not
       (contains "\"property\":\"background\",\"value\":\"background\""
          patch));
  ignore (Native_bridge.dispose ())

let kotlin_node_route_owns_an_opaque_background () =
  let route = node_projection "node-a" "page-a" "Project" [] [] in
  ignore (Native_bridge.initialize 3 4 3);
  ignore (Native_bridge.flush_action (Model.RequestAppNode "node-a"));
  let patch =
    Native_bridge.flush_action
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           graph_name = Some "Work";
           selected_graph_id = Some "graph-a";
           node_routes = [ route ];
         })
  in
  check ~msg:"opening a Kotlin node mounts the node screen"
    (contains "screen.node" patch);
  check ~msg:"Kotlin node routes cover the retained journal surface"
    (contains "\"property\":\"background\",\"value\":\"background\"" patch);
  ignore (Native_bridge.dispose ());
  ignore (Native_bridge.initialize 2 2 3);
  ignore (Native_bridge.flush_action (Model.RequestAppNode "node-a"));
  let patch =
    Native_bridge.flush_action
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           graph_name = Some "Work";
           selected_graph_id = Some "graph-a";
           node_routes = [ route ];
         })
  in
  check
    ~msg:"the Kotlin-only node backdrop does not alter SwiftUI navigation"
    (not
       (contains "\"property\":\"background\",\"value\":\"background\""
          patch));
  ignore (Native_bridge.dispose ())

let native_bridge_drains_and_resolves_typed_effects_once () =
  ignore (Native_bridge.initialize 2 2 0);
  let application = Native_bridge.app () in
  send application Model.ExpandComposer;
  send application
    (Model.ChangeComposerDraft "Project \"alpha\"\nNext");
  send application Model.SendComposer;
  flush application;
  let persist_dispatch = Native_bridge.take_effect () in
  let capture_dispatch = Native_bridge.take_effect () in
  check ~msg:"the bridge clears persisted text before capture"
    (contains
       "\"effect\":{\"id\":2,\"kind\":\"persist-composer-draft\",\"text\":\"\"}"
       persist_dispatch);
  check ~msg:"the bridge emits escaped capture JSON for the host executor"
    (contains
       "\"effect\":{\"id\":3,\"kind\":\"send-capture\",\"text\":\"Project \
        \\\"alpha\\\"\\nNext\"}"
       capture_dispatch);
  check ~msg:"each dispatch explicitly carries its dequeue patch"
    (contains "\"patch\":" persist_dispatch
    && contains "\"patch\":" capture_dispatch);
  check_eq ~msg:"an effect is never dispatched to the host twice"
    (Native_bridge.take_effect ()) "";
  check_eq ~msg:"dequeued effects remain tracked until resolution"
    (App.model application).in_flight_effects
    [
      Model.PersistComposerDraftEffect (2, "");
      Model.SendCaptureEffect (3, "Project \"alpha\"\nNext");
    ];
  ignore (Native_bridge.resolve_effect 2 true "");
  ignore (Native_bridge.resolve_effect 3 false "Network unavailable");
  check_eq ~msg:"resolution retires the matching in-flight effect"
    (App.model application).in_flight_effects [];
  check_eq ~msg:"effect failures return to LG-owned application state"
    (App.model application).effect_error (Some "Network unavailable");
  ignore (Native_bridge.dispose ())

let successful_effect_resolution_preserves_the_core_response_for_projection
    () =
  let drafted =
    Model.update (Model.initial ())
      (Model.ChangeComposerDraft "Project note")
  in
  let queued = Model.update drafted Model.SendComposer in
  let dequeued = Model.update queued (Model.DequeueEffect 3) in
  let resolved =
    Model.update dequeued
      (Model.ResolveEffect (3, true, "{\"ok\":true}"))
  in
  check_eq ~msg:"success retires the in-flight effect"
    resolved.in_flight_effects [];
  check_eq ~msg:"success clears the visible effect failure"
    resolved.effect_error None;
  check_eq
    ~msg:"the LG projection boundary receives the core response"
    resolved.last_core_response (Some "{\"ok\":true}")

let app_navigation_matches_the_main_branch_path_contract () =
  let initial = Model.initial () in
  let first_request =
    Model.update initial (Model.RequestAppNode "page-a")
  in
  let duplicate_request =
    Model.update first_request (Model.RequestAppNode "page-a")
  in
  let nested_request =
    Model.update duplicate_request (Model.RequestAppNode "page-b")
  in
  check_eq ~msg:"the first node request pushes one route"
    first_request.app_navigation_path
    [ Model.NodeRoute "page-a" ];
  check_eq ~msg:"a consecutive duplicate route is not pushed"
    duplicate_request.app_navigation_path
    first_request.app_navigation_path;
  check_eq ~msg:"a distinct nested route is appended"
    nested_request.app_navigation_path
    [ Model.NodeRoute "page-a"; Model.NodeRoute "page-b" ];
  check_eq ~msg:"a resolved route remains presented"
    (Model.update nested_request (Model.ResolveAppNode ("page-b", true)))
      .app_navigation_path
    nested_request.app_navigation_path;
  check_eq ~msg:"an unresolved route is removed"
    (Model.update nested_request (Model.ResolveAppNode ("page-b", false)))
      .app_navigation_path
    [ Model.NodeRoute "page-a" ];
  check_eq ~msg:"the back action removes exactly one route"
    (Model.update nested_request (Model.BackAppNavigation 1))
      .app_navigation_path
    [ Model.NodeRoute "page-a" ]

let native_header_title_follows_the_active_destination () =
  let initial = Model.initial () in
  let page = { Model.uuid = "page-a"; title = "Project" } in
  let route = node_projection "node-a" "page-a" "Nested" [] [] in
  let routed =
    {
      initial with
      Model.node_routes = [ route ];
      app_navigation_path = [ Model.NodeRoute "node-a" ];
    }
  in
  check_eq ~msg:"journals do not repeat their destination name in the header"
    (View_base.main_title initial) "";
  check_eq ~msg:"selected pages use their projected title"
    (View_base.main_title
       { initial with Model.selected_page = Some page })
    "Project";
  check_eq ~msg:"native routes use their projected title"
    (View_base.main_title routed) "Nested";
  check_eq ~msg:"flashcards use their destination title"
    (View_base.main_title
       { initial with Model.destination = Model.FlashcardsDestination })
    "Flashcards";
  check_eq ~msg:"graphs use their destination title"
    (View_base.main_title
       { initial with Model.destination = Model.GraphsDestination })
    "Graphs"

let native_header_title_follows_the_optimistic_navigation_path () =
  let initial = Model.initial () in
  let route_a = node_projection "node-a" "page-a" "Project" [] [] in
  let route_b = node_projection "node-b" "page-b" "Nested" [] [] in
  let prepared =
    { initial with Model.app_navigation_previews = [ route_a; route_b ] }
  in
  let requested_a =
    Model.update prepared (Model.RequestAppNode "node-a")
  in
  let opened_a =
    { requested_a with Model.node_routes = [ route_a ] }
  in
  let requested_b =
    Model.update opened_a (Model.RequestAppNode "node-b")
  in
  let opened_b =
    { requested_b with Model.node_routes = [ route_a; route_b ] }
  in
  let returned_a =
    Model.update opened_b (Model.BackAppNavigation 1)
  in
  let returned_root =
    Model.update returned_a (Model.BackAppNavigation 1)
  in
  check_eq ~msg:"push uses the preview title before open-node resolves"
    (View_base.main_title requested_a) "Project";
  check_eq ~msg:"push exposes destination actions with the optimistic route"
    (View_base.active_page_actions_visible_ requested_a) true;
  check_eq ~msg:"a nested push immediately uses its requested route title"
    (View_base.main_title requested_b) "Nested";
  check_eq
    ~msg:"one native pop immediately restores the preceding route title"
    (View_base.main_title returned_a) "Project";
  check_eq ~msg:"one native pop keeps the preceding destination actions"
    (View_base.active_page_actions_visible_ returned_a) true;
  check_eq ~msg:"returning to root does not wait for close-node projections"
    (View_base.main_title returned_root) "";
  check_eq ~msg:"returning to root immediately restores settings actions"
    (View_base.active_page_actions_visible_ returned_root) false

let native_back_count_is_reduced_as_one_navigation_transition () =
  let requested_a =
    Model.update (Model.initial ()) (Model.RequestAppNode "page-a")
  in
  let requested_b =
    Model.update requested_a (Model.RequestAppNode "page-b")
  in
  let returned =
    Model.update requested_b (Model.BackAppNavigation 2)
  in
  check_eq ~msg:"one native callback removes its complete returned path"
    returned.app_navigation_path [];
  check_eq
    ~msg:"the one transition retains top-to-root core close ordering"
    returned.pending_effects
    [
      Model.OpenAppNodeEffect (1, "page-a");
      Model.OpenAppNodeEffect (2, "page-b");
      Model.CloseAppNodeEffect (3, "page-b");
      Model.CloseAppNodeEffect (4, "page-a");
    ]

let navigation_requests_and_back_cross_the_core_effect_boundary () =
  let requested =
    Model.update (Model.initial ()) (Model.RequestSearchNode "node-a")
  in
  let returned = Model.update requested (Model.BackSearchNavigation 1) in
  check_eq ~msg:"search navigation remains optimistic"
    requested.search_navigation_path
    [ Model.NodeRoute "node-a" ];
  check_eq ~msg:"opening a search node calls the core"
    requested.pending_effects
    [ Model.OpenSearchNodeEffect (1, "node-a") ];
  check_eq ~msg:"back pops the visible search route"
    returned.search_navigation_path [];
  check_eq ~msg:"back closes the matching core projection"
    returned.pending_effects
    [
      Model.OpenSearchNodeEffect (1, "node-a");
      Model.CloseSearchNodeEffect (2, "node-a");
    ]

let native_search_back_and_dismiss_own_the_full_screen_search_path () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  send application (Model.RequestAppNode "app-node");
  send application (Model.RequestSearchNode "search-node");
  flush application;
  let navigation = extension_node application "native-search-presentation" in
  check_eq ~msg:"native search owns a stable navigation title"
    (extension_property application navigation "title")
    (Some (Lui_protocol.StringValue "Search"));
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-search-presentation",
         "back",
         Lui_protocol.String_map.singleton "count"
           (Lui_protocol.IntValue 1) ));
  flush application;
  check_eq ~msg:"native back leaves the underlying app route intact"
    (App.model application).app_navigation_path
    [ Model.NodeRoute "app-node" ];
  check_eq ~msg:"native back first pops the full-screen search route"
    (App.model application).search_navigation_path [];
  check_eq ~msg:"native search back closes the matching core projection"
    (App.model application).pending_effects
    [
      Model.OpenAppNodeEffect (1, "app-node");
      Model.OpenSearchNodeEffect (2, "search-node");
      Model.CloseSearchNodeEffect (3, "search-node");
    ];
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-search-presentation",
         "dismiss",
         Lui_protocol.String_map.empty ));
  flush application;
  check ~msg:"system dismissal closes the LG-owned search presentation"
    (not (App.model application).search_open)

let native_search_query_event_updates_the_lg_search_model () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  send application Model.OpenSearch;
  flush application;
  let navigation = extension_node application "native-search-presentation" in
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-search-presentation",
         "query-changed",
         Lui_protocol.String_map.singleton "query"
           (Lui_protocol.StringValue "project alpha") ));
  flush application;
  check_eq ~msg:"native searchable text must remain LG-owned state"
    (App.model application).search_query "project alpha"

let destination_navigation_ends_active_outliner_editing () =
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Draft";
      caret_utf16_offset = 5;
    }
  in
  let current =
    { (Model.initial ()) with Model.outliner_editing = Some editing }
  in
  let node = Model.update current (Model.RequestAppNode "page-a") in
  let sidebar = Model.update current (Model.SelectSidebarPage "page-a") in
  let journals = Model.update current Model.ShowJournals in
  let flashcards = Model.update current Model.ShowFlashcards in
  let graphs = Model.update current Model.ShowGraphs in
  let graph_switch =
    Model.update
      {
        current with
        Model.graphs = [ graph "graph-a" "Work" false true ];
      }
      (Model.RequestOpenGraph "graph-a")
  in
  let nested =
    {
      current with
      Model.app_navigation_path = [ Model.NodeRoute "page-a" ];
    }
  in
  let nested_sidebar =
    Model.update nested (Model.SelectSidebarPage "page-b")
  in
  let nested_journals = Model.update nested Model.ShowJournals in
  let nested_flashcards = Model.update nested Model.ShowFlashcards in
  let nested_graphs = Model.update nested Model.ShowGraphs in
  List.iter
    (fun updated ->
       check_eq
         ~msg:"destination changes clear the retained editor immediately"
         updated.Model.outliner_editing None)
    [ node; sidebar; journals; flashcards; graphs; graph_switch ];
  List.iter
    (fun updated ->
       check_eq
         ~msg:"sidebar destinations return the native stack to its root"
         updated.Model.app_navigation_path [])
    [ nested_sidebar; nested_journals; nested_flashcards; nested_graphs ];
  check_eq ~msg:"node navigation cancels editing before opening the route"
    (List.length node.pending_effects) 2;
  check_eq ~msg:"sidebar navigation cancels editing before selecting the page"
    (List.length sidebar.pending_effects) 2;
  check_eq ~msg:"a local-only destination still cancels core editing"
    (List.length graphs.pending_effects) 1;
  check_eq ~msg:"graph switches cancel editing before opening the graph"
    (List.length graph_switch.pending_effects) 2

let failed_navigation_effects_restore_the_optimistic_path () =
  let requested =
    Model.update (Model.initial ()) (Model.RequestAppNode "node-a")
  in
  let opening = Model.update requested (Model.DequeueEffect 1) in
  let open_failed =
    Model.update opening (Model.ResolveEffect (1, false, "Open failed"))
  in
  let opened_again =
    Model.update open_failed (Model.RequestAppNode "node-a")
  in
  let opened =
    Model.update
      (Model.update opened_again (Model.DequeueEffect 2))
      (Model.ResolveEffect (2, true, "{\"ok\":true}"))
  in
  let returned = Model.update opened (Model.BackAppNavigation 1) in
  let closing = Model.update returned (Model.DequeueEffect 3) in
  let close_failed =
    Model.update closing (Model.ResolveEffect (3, false, "Close failed"))
  in
  check_eq ~msg:"a failed open removes its optimistic route"
    open_failed.app_navigation_path [];
  check_eq ~msg:"a failed close restores the optimistically popped route"
    close_failed.app_navigation_path
    [ Model.NodeRoute "node-a" ]

let active_node_route_renders_a_core_backed_navigation_screen () =
  let application = App.create (ios_backend ()) in
  let row =
    {
      (outline_row "child" "Child") with
      Model.depth = 1;
    }
  in
  let route =
    {
      (node_projection "node-a" "node-a" "Project"
         [
           {
             (outline_row "reference" "Linked from journal") with
             row_breadcrumb = "Journal";
             row_breadcrumbs = [ { Model.uuid = "journal"; title = "Journal" } ];
           };
         ]
         [])
      with
      Model.node_outliner_rows = [ row ];
    }
  in
  start application;
  send application (Model.RequestAppNode "node-a");
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" []
       [ route ] None None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let screen =
    descendant_with_identifier renderer navigation "screen.node"
  in
  let title =
    descendant_with_identifier renderer screen "title.node"
  in
  let title_layout =
    descendant_with_identifier renderer screen "layout.node.title"
  in
  let outliner =
    descendant_with_identifier renderer screen "list.outliner"
  in
  let content = outliner in
  let top_inset = List.nth (children renderer content) 0 in
  let related =
    descendant_with_identifier renderer outliner
      "section.node.linked-references"
  in
  let breadcrumb =
    descendant_with_identifier renderer outliner
      "breadcrumb.related-blocks"
  in
  let journal =
    descendant_with_identifier renderer outliner "button.breadcrumb.journal"
  in
  check_eq ~msg:"the route title comes from the core projection"
    (property_string renderer title Lui_protocol.TextValue)
    "Project";
  check_eq ~msg:"node scrolling surface stays full width like main"
    (property_int renderer content Lui_protocol.PaddingHorizontal)
    (-1);
  check_eq
    ~msg:"node content uses explicit main spacing instead of a global gap"
    (property_int renderer content Lui_protocol.Gap)
    0;
  check_eq ~msg:"node content starts at main's native-navigation inset"
    (property_int renderer top_inset Lui_protocol.HeightValue)
    16;
  check_eq ~msg:"node section titles use main's title2 typography"
    (property_int renderer title Lui_protocol.HeadingLevel)
    3;
  check_eq ~msg:"node section titles add main's inner horizontal inset"
    (property_int renderer title_layout Lui_protocol.PaddingHorizontal)
    16;
  check ~msg:"node routes render their linked references section"
    (related <> -1);
  check ~msg:"related rows reuse the breadcrumb component with native separators"
    (node renderer breadcrumb = Some Lui_protocol.Breadcrumb);
  let heading =
    descendant_with_identifier renderer related "title.related-section"
  in
  check_eq ~msg:"related section labels are smaller than page titles"
    (property_string renderer heading Lui_protocol.StyleClass)
    "subheadline";
  check_eq ~msg:"related section labels use secondary text color"
    (property_string renderer heading Lui_protocol.ForegroundValue)
    "muted-foreground";
  check ~msg:"each structured breadcrumb remains independently navigable"
    (journal <> -1);
  dispatch application (Lui_protocol.Press journal);
  flush application;
  check_eq ~msg:"pressing a breadcrumb opens its retained node identity"
    (App.model application).app_navigation_path
    [ Model.NodeRoute "node-a"; Model.NodeRoute "journal" ];
  send application (Model.BackAppNavigation 1);
  flush application;
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-navigation-stack",
         "back",
         Lui_protocol.String_map.singleton "count"
           (Lui_protocol.IntValue 1) ));
  flush application;
  check_eq ~msg:"native back removes the presented route"
    (App.model application).app_navigation_path []

let ios_node_navigation_is_owned_by_the_native_stack () =
  let application = App.create (ios_backend ()) in
  let route = node_projection "node-a" "page-a" "Project" [] [] in
  start application;
  send application (Model.RequestAppNode "node-a");
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" []
       [ route ] None None [] [] [] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let screen =
    descendant_with_identifier renderer navigation "screen.node"
  in
  let chrome = native_bottom_chrome renderer application in
  check_eq
    ~msg:"SwiftUI node navigation does not receive Kotlin flex sizing"
    (property_float renderer screen Lui_protocol.GrowValue)
    0.0;
  check_eq ~msg:"the retained node does not duplicate the system back button"
    (child_with_identifier renderer screen "BackButton")
    (-1);
  check_eq ~msg:"node content does not contain a duplicate composer"
    (descendant_with_identifier renderer screen "surface.composer.root")
    (-1);
  check ~msg:"the global bottom slot keeps Capture on node pages like main"
    (descendant_with_identifier renderer chrome "surface.composer.root"
    <> -1);
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-navigation-stack",
         "back",
         Lui_protocol.String_map.singleton "count"
           (Lui_protocol.IntValue 1) ));
  flush application;
  check_eq ~msg:"the native iOS back action pops the LG route"
    (App.model application).app_navigation_path []

let kotlin_navigation_and_search_own_composed_standard_children () =
  let application = App.create (kotlin_backend ()) in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "test-graph";
         graph_name = Some "Work";
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let search = extension_node application "native-search-presentation" in
  let navigation_children = children renderer navigation in
  let search_children = children renderer search in
  check_eq ~msg:"Kotlin navigation receives content plus bottom chrome"
    (List.length navigation_children) 2;
  check_eq ~msg:"Kotlin search receives one composed child"
    (List.length search_children) 1;
  let navigation_content = List.nth navigation_children 0 in
  let navigation_chrome = List.nth navigation_children 1 in
  let search_content = List.nth search_children 0 in
  let navigation_title =
    descendant_with_identifier renderer navigation_content "title.main"
  in
  let capture_row =
    descendant_with_identifier renderer navigation_chrome
      "row.bottom.capture"
  in
  check_eq ~msg:"the composed Kotlin child uses iOS headline text"
    (node renderer navigation_title)
    (Some Lui_protocol.Text);
  check_eq ~msg:"the Kotlin navigation title maps to the iOS headline class"
    (property_string renderer navigation_title Lui_protocol.StyleClass)
    "headline";
  check ~msg:"the composed Kotlin child owns the bottom controls"
    (descendant_with_identifier renderer navigation_chrome "button.search"
    <> -1);
  check ~msg:"the closed Kotlin search child retains journal content"
    (descendant_with_identifier renderer search_content "list.outliner"
    <> -1);
  check_eq
    ~msg:"Kotlin capture fills the bottom dock like iOS"
    (property_float renderer capture_row Lui_protocol.GrowValue)
    1.0;
  send application Model.ExpandComposer;
  flush application;
  let expanded_row =
    descendant_with_identifier renderer navigation_chrome
      "row.composer.placement"
  in
  check_eq
    ~msg:"Kotlin expanded Capture uses intrinsic height inside the bottom overlay"
    (property_float renderer expanded_row Lui_protocol.GrowValue)
    (-1.0)

let kotlin_navigation_renders_each_active_node_row_once () =
  let application = App.create (kotlin_backend ()) in
  let row =
    journal_outline_row "route-child" "route-page" "Route child" "" 0 0
  in
  let route =
    {
      (node_projection "node-a" "page-a" "Project" [] []) with
      Model.node_outliner_rows = [ row ];
    }
  in
  start application;
  send application (Model.RequestAppNode "node-a");
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graph_name = Some "Work";
         selected_graph_id = Some "test-graph";
         node_routes = [ route ];
         outliner_rows = [ row ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let screen =
    descendant_with_identifier renderer navigation "screen.node"
  in
  let back_button =
    descendant_with_identifier renderer navigation "button.navigation.back"
  in
  check
    ~msg:"Kotlin node destinations expose a Material top-app-bar back action"
    (back_button <> -1);
  check_eq ~msg:"the Android back action remains available to TalkBack"
    (property_string renderer back_button Lui_protocol.AccessibilityLabel)
    "Back";
  check_eq ~msg:"Kotlin node content receives a bounded flex height"
    (property_float renderer screen Lui_protocol.GrowValue)
    1.0;
  check_eq
    ~msg:
      "Kotlin keeps the journal as the stack root instead of duplicating \
       the active node route"
    (descendant_count_with_identifier renderer navigation
       "outliner.block.route-child")
    1;
  dispatch application (Lui_protocol.Press back_button);
  flush application;
  check_eq ~msg:"the visible Android back action pops exactly one route"
    (App.model application).app_navigation_path []

let kotlin_selected_pages_unmount_the_hidden_journal_pane () =
  let application = App.create (kotlin_backend ()) in
  let page = { Model.uuid = "page-a"; title = "Project" } in
  let row =
    journal_outline_row "selected-row" "page-a" "Selected row" "" 0 0
  in
  let journal_row =
    journal_outline_row "journal-row" "journal-page" "Journal row" "Journal"
      20260901 0
  in
  let sidebar =
    {
      (empty_sidebar_projection ()) with
      Model.favorites = [ page ];
      selected_page = Some page;
    }
  in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graph_name = Some "Work";
         selected_graph_id = Some "test-graph";
         sidebar;
         outliner_rows = [ row ];
         journal_outliner_rows = [ journal_row ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  check ~msg:"Kotlin renders the selected page"
    (descendant_with_identifier renderer navigation "pane.selected-page"
    <> -1);
  check_eq
    ~msg:
      "Kotlin removes the hidden journal so it cannot paint or receive \
       input behind the selected page"
    (descendant_with_identifier renderer navigation "pane.journals")
    (-1)

let kotlin_selected_page_navigation_renders_the_opened_node () =
  let application = App.create (kotlin_backend ()) in
  let page = { Model.uuid = "page-a"; title = "Project" } in
  let selected_row =
    journal_outline_row "selected-row" "page-a" "Selected row" "" 0 0
  in
  let route_row =
    journal_outline_row "route-row" "route-page" "Opened row" "" 0 0
  in
  let route =
    {
      (node_projection "node-a" "route-page" "Opened page" [] []) with
      Model.node_outliner_rows = [ route_row ];
    }
  in
  let sidebar =
    {
      (empty_sidebar_projection ()) with
      Model.favorites = [ page ];
      selected_page = Some page;
    }
  in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graph_name = Some "Work";
         selected_graph_id = Some "test-graph";
         sidebar;
         outliner_rows = [ selected_row ];
       });
  send application (Model.RequestAppNode "node-a");
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graph_name = Some "Work";
         selected_graph_id = Some "test-graph";
         sidebar;
         node_routes = [ route ];
         outliner_rows = [ route_row ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  check_eq ~msg:"Kotlin renders the opened route above an existing selected page"
    (descendant_count_with_identifier renderer navigation
       "outliner.block.route-row")
    1;
  check_eq
    ~msg:"Kotlin unmounts the selected-page root while a node route is active"
    (descendant_with_identifier renderer navigation "pane.selected-page")
    (-1)

let native_navigation_retains_the_journal_and_every_node_route () =
  let application = App.create (ios_backend ()) in
  let journal_row =
    journal_outline_row "journal" "journal-page" "Journal" "Aug 27th, 2026"
      20260827 0
  in
  let first_row =
    journal_outline_row "first-child" "first-page" "First child" "" 0 0
  in
  let second_row =
    journal_outline_row "second-child" "second-page" "Second child" "" 0 0
  in
  let first_route =
    {
      (node_projection "node-a" "page-a" "First" [] []) with
      Model.node_outliner_rows = [ first_row ];
    }
  in
  let second_route =
    {
      (node_projection "node-b" "page-b" "Second" [] []) with
      Model.node_outliner_rows = [ second_row ];
    }
  in
  let projection =
    {
      (empty_core_projection ()) with
      graph_name = Some "Work";
      selected_graph_id = Some "test-graph";
      node_routes = [ first_route; second_route ];
      journal_outliner_rows = [ journal_row ];
      outliner_rows = [ second_row ];
    }
  in
  start application;
  send application (Model.RequestAppNode "node-a");
  send application (Model.RequestAppNode "node-b");
  send application (Model.ApplyCoreSnapshot projection);
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  check ~msg:"the Outliner is hosted by the native navigation extension"
    (navigation <> -1);
  check_eq ~msg:"the native path depth follows LG state"
    (extension_property application navigation "depth")
    (Some (Lui_protocol.IntValue 2));
  let nav_children = children renderer navigation in
  check_eq ~msg:"native chrome slots remain separate from retained routes"
    (List.length nav_children) 8;
  check ~msg:"the navigation root retains the journal Outliner"
    (descendant_with_identifier renderer (List.nth nav_children 0)
       "outliner.block.journal"
    <> -1);
  check_eq
    ~msg:"the journal stays visible underneath an interactive pop"
    (property_bool renderer
       (descendant_with_identifier renderer (List.nth nav_children 0)
          "list.outliner")
       Lui_protocol.Selected)
    true;
  check_eq ~msg:"the retained root keeps its sidebar ready for interactive pop"
    (List.length (children renderer (List.nth nav_children 1)))
    1;
  check_eq ~msg:"LG supplies the native title"
    (property_string renderer (List.nth nav_children 2)
       Lui_protocol.AccessibilityIdentifier)
    "title.main";
  check_eq ~msg:"LG supplies the native sync control"
    (property_string renderer
       (descendant_with_identifier renderer (List.nth nav_children 3)
          "sync.disconnected")
       Lui_protocol.InlineIconName)
    "app:status-dot";
  check ~msg:"LG supplies the native trailing menu"
    (descendant_with_node_kind renderer
       (List.nth (children renderer (List.nth nav_children 4)) 0)
       Lui_protocol.MenuTrigger
    <> -1);
  check_eq
    ~msg:
      "the internal bottom chrome slot does not override its active \
       control identifier"
    (property_string renderer (List.nth nav_children 5)
       Lui_protocol.AccessibilityIdentifier)
    "<missing>";
  check ~msg:"the first pushed route retains its own Outliner"
    (descendant_with_identifier renderer (List.nth nav_children 6)
       "outliner.block.first-child"
    <> -1);
  check ~msg:"the active route renders the deepest Outliner"
    (descendant_with_identifier renderer (List.nth nav_children 7)
       "outliner.block.second-child"
    <> -1);
  check_eq ~msg:"the incoming retained page owns its native title"
    (extension_property application (List.nth nav_children 6) "title")
    (Some (Lui_protocol.StringValue "First"));
  check_eq ~msg:"the outgoing page owns a separate native title"
    (extension_property application (List.nth nav_children 7) "title")
    (Some (Lui_protocol.StringValue "Second"));
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-navigation-stack",
         "back",
         Lui_protocol.String_map.singleton "count"
           (Lui_protocol.IntValue (-1)) ));
  flush application;
  check_eq ~msg:"an invalid native back count does not mutate the path"
    (App.model application).app_navigation_path
    [ Model.NodeRoute "node-a"; Model.NodeRoute "node-b" ];
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( navigation,
         "native-navigation-stack",
         "back",
         Lui_protocol.String_map.singleton "count"
           (Lui_protocol.IntValue 5) ));
  flush application;
  check_eq ~msg:"a native multi-pop is safely clamped to the LG path"
    (App.model application).app_navigation_path []

let native_navigation_retains_repeated_node_visits () =
  let application = App.create (ios_backend ()) in
  let route_a = node_projection "node-a" "page-a" "Tag" [] [] in
  let route_b = node_projection "node-b" "page-b" "Block" [] [] in
  start application;
  send application (Model.RequestAppNode "node-a");
  send application (Model.RequestAppNode "node-b");
  send application
    (Model.ApplyCoreSnapshot
       { (empty_core_projection ()) with
         selected_graph_id = Some "test-graph";
         node_routes = [ route_a; route_b ] });
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let retained = Model.sub_list 6 8 (children renderer navigation) in
  send application (Model.RequestAppNode "node-a");
  flush application;
  check_eq ~msg:"revisiting an ancestor pushes another destination"
    (extension_property application navigation "depth")
    (Some (Lui_protocol.IntValue 3));
  let visits = Model.sub_list 6 9 (children renderer navigation) in
  check_eq ~msg:"each visit owns a distinct retained native screen"
    (List.length (List.sort_uniq compare visits)) 3;
  check_eq ~msg:"pushing a revisit preserves preceding native screens"
    (Model.sub_list 0 2 visits) retained;
  send application (Model.BackAppNavigation 1);
  flush application;
  check_eq ~msg:"back removes only the newest visit"
    (App.model application).app_navigation_path
    [ Model.NodeRoute "node-a"; Model.NodeRoute "node-b" ];
  check_eq ~msg:"back restores the preceding native screens unchanged"
    (Model.sub_list 6 8 (children renderer navigation)) retained

let journal_navigation_exposes_an_immediate_preview_route () =
  let row =
    journal_outline_row "journal-block" "journal-page" "Journal row"
      "Aug 27th, 2026" 20260827 0
  in
  let current =
    {
      (Model.initial ()) with
      Model.journal_outliner_rows = [ row ];
      outliner_section_markers = Model.journal_section_markers [ row ];
    }
  in
  let requested = Model.update current (Model.RequestAppNode "journal-page") in
  let routes = Model.app_node_routes requested in
  let returned = Model.update requested (Model.BackAppNavigation 1) in
  check_eq ~msg:"the model publishes a route before core resolution"
    (List.length routes) 1;
  check_eq ~msg:"the preview route keeps the requested page identity"
    (List.hd routes).Model.node_uuid "journal-page";
  check_eq ~msg:"the preview route uses the visible journal title"
    (List.hd routes).Model.node_title "Aug 27th, 2026";
  check_eq ~msg:"the preview route reuses the already projected journal rows"
    (List.hd routes).Model.node_outliner_rows [ row ];
  check_eq ~msg:"leaving the route releases its optimistic preview"
    returned.app_navigation_previews []

let block_navigation_exposes_an_immediate_outliner_preview_route () =
  let parent =
    {
      (journal_outline_row "parent" "journal-page" "Parent" "Sep 14th, 2026"
         20260914 0)
      with
      Model.has_children = true;
    }
  in
  let child =
    journal_outline_row "child" "journal-page" "Child" "Sep 14th, 2026"
      20260914 1
  in
  let sibling =
    journal_outline_row "sibling" "journal-page" "Sibling" "Sep 14th, 2026"
      20260914 0
  in
  let editing =
    {
      Model.editing_uuid = "child";
      editing_title = "Child";
      caret_utf16_offset = 5;
    }
  in
  let current =
    {
      (Model.initial ()) with
      Model.journal_outliner_rows = [ parent; child; sibling ];
      outliner_rows = [ parent; child; sibling ];
      outliner_editing = Some editing;
    }
  in
  let requested = Model.update current (Model.RequestAppNode "parent") in
  let routes = Model.app_node_routes requested in
  check_eq ~msg:"block zoom publishes a native route before core resolution"
    (List.length routes) 1;
  check_eq ~msg:"the preview route keeps the requested block identity"
    (List.hd routes).Model.node_uuid "parent";
  check_eq ~msg:"the preview route keeps the containing page identity"
    (List.hd routes).Model.node_page_uuid "journal-page";
  check_eq ~msg:"the preview route owns the selected subtree"
    (List.hd routes).Model.node_outliner_rows [ parent; child ];
  check_eq ~msg:"opening a block route exits inline editing"
    requested.outliner_editing None

let popped_native_path_restores_root_before_core_route_cleanup () =
  let route = node_projection "node-a" "page-a" "Project" [] [] in
  let current =
    {
      (Model.initial ()) with
      Model.destination = Model.JournalsDestination;
      selected_graph_id = Some "test-graph";
      graph_loading = false;
      node_routes = [ route ];
      app_navigation_path = [];
    }
  in
  check
    ~msg:"the visible navigation layer follows the already-popped native path"
    (View_base.node_navigation_inactive_ current);
  check ~msg:"the journal root is restored during the native pop transition"
    (View_base.journal_root_visible_ current);
  check ~msg:"the root header returns before delayed core route cleanup"
    (View_base.primary_sidebar_button_visible_ current)

let app_and_search_routes_are_retained_by_distinct_native_stacks () =
  let application = App.create (ios_backend ()) in
  let app_row =
    journal_outline_row "app-child" "app-page" "App child" "" 0 0
  in
  let search_row =
    journal_outline_row "search-child" "search-page" "Search child" "" 0 0
  in
  let app_route =
    {
      (node_projection "app-node" "app-page" "App" [] []) with
      Model.node_outliner_rows = [ app_row ];
    }
  in
  let search_route =
    {
      (node_projection "search-node" "search-page" "Search" [] []) with
      Model.node_outliner_rows = [ search_row ];
    }
  in
  start application;
  send application (Model.RequestAppNode "app-node");
  send application Model.OpenSearch;
  send application (Model.RequestSearchNode "search-node");
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         graph_name = Some "Work";
         selected_graph_id = Some "test-graph";
         node_routes = [ app_route; search_route ];
         outliner_rows = [ search_row ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let app_navigation = extension_node application "native-navigation-stack" in
  let search_navigation =
    extension_node application "native-search-presentation"
  in
  let app_children = children renderer app_navigation in
  let search_children = children renderer search_navigation in
  check_eq ~msg:"the app stack owns only the app route depth"
    (extension_property application app_navigation "depth")
    (Some (Lui_protocol.IntValue 1));
  check_eq ~msg:"the full-screen search stack owns only its route depth"
    (extension_property application search_navigation "depth")
    (Some (Lui_protocol.IntValue 1));
  check_eq ~msg:"the app stack retains chrome, its root, and app route"
    (List.length app_children) 7;
  check_eq
    ~msg:"search retains the app surface, search root, and search route"
    (List.length search_children) 3;
  check ~msg:"the app route remains behind the search presentation"
    (descendant_with_identifier renderer (List.nth app_children 6)
       "outliner.block.app-child"
    <> -1);
  check ~msg:"the search route is retained only by the search stack"
    (descendant_with_identifier renderer (List.nth search_children 2)
       "outliner.block.search-child"
    <> -1)

let closed_search_does_not_render_core_node_routes () =
  let route = node_projection "node-a" "page-a" "Node" [] [] in
  let closed =
    {
      (Model.initial ()) with
      Model.node_routes = [ route ];
      search_open = false;
    }
  in
  let opened = { closed with Model.search_open = true } in
  check_eq ~msg:"closed search never overlays core node routes on the app"
    (View_base.search_node_routes closed) [];
  check_eq ~msg:"open search retains its unresolved route suffix"
    (View_base.search_node_routes opened) [ route ]

let empty_node_routes_add_the_first_block_through_the_core () =
  let application = App.create (ios_backend ()) in
  let route = node_projection "page-a" "page-a" "Empty page" [] [] in
  start application;
  send application (Model.RequestAppNode "page-a");
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" []
       [ route ] None None [] [] [] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let screen =
    descendant_with_identifier renderer navigation "screen.node"
  in
  let add_button =
    descendant_with_identifier renderer screen
      "button.outliner.add-first-block"
  in
  dispatch application (Lui_protocol.Press add_button);
  flush application;
  check_eq ~msg:"empty pages reuse the core addRootBlock outliner action"
    (App.model application).pending_effects
    [
      Model.OpenAppNodeEffect (1, "page-a");
      Model.AddRootBlockEffect (2, "page-a");
    ]

let older_journals_use_an_invisible_scroll_sentinel () =
  let application = App.create (ios_backend ()) in
  let projection =
    {
      (empty_core_projection ()) with
      selected_graph_id = Some "test-graph";
      has_older_journals = true;
    }
  in
  start application;
  send application (Model.ApplyCoreSnapshot projection);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let sentinel =
    descendant_with_identifier renderer root
      "outliner.load-older-sentinel"
  in
  let outliner_children = children renderer outliner in
  let bottom_spacer =
    List.nth outliner_children (List.length outliner_children - 1)
  in
  check_eq ~msg:"main does not expose load-more as a visible button"
    (descendant_with_identifier renderer root
       "button.outliner.load-older-journals")
    (-1);
  check ~msg:"journals expose an invisible end-of-scroll sentinel"
    (sentinel <> -1);
  check_eq ~msg:"the sentinel remains inside the virtualized Outliner"
    (descendant_with_identifier renderer outliner
       "outliner.load-older-sentinel")
    sentinel;
  check_eq ~msg:"the sentinel matches main's one-point marker"
    (property_int renderer sentinel Lui_protocol.HeightValue)
    1;
  check_eq ~msg:"main keeps bottom padding after the pagination marker"
    (property_int renderer bottom_spacer Lui_protocol.HeightValue)
    120;
  check
    ~msg:"pagination begins before the user reaches the absolute scroll edge"
    (sentinel <> bottom_spacer);
  check_eq ~msg:"retained rendering alone does not eagerly load journals"
    (App.model application).pending_effects [];
  send application
    (Model.ApplyCoreSnapshot
       { projection with has_older_journals = false });
  flush application;
  check_eq
    ~msg:"the sentinel disappears when the core reaches the oldest journal"
    (descendant_with_identifier renderer (main_root renderer application)
       "outliner.load-older-sentinel")
    (-1)

let older_journals_only_appear_at_the_journal_root () =
  let available =
    {
      (Model.initial ()) with
      Model.selected_graph = Some "Work";
      has_older_journals = true;
    }
  in
  let selected_page =
    {
      available with
      Model.selected_page =
        Some { Model.uuid = "page-a"; title = "Page" };
    }
  in
  let nested =
    {
      available with
      Model.node_routes = [ node_projection "node-a" "page-a" "Node" [] [] ];
      app_navigation_path = [ Model.NodeRoute "node-a" ];
    }
  in
  check ~msg:"older journals appear at the journal root"
    (View_base.older_journals_visible_ available);
  check ~msg:"older journals hide on selected pages"
    (not (View_base.older_journals_visible_ selected_page));
  check ~msg:"older journals hide on nested routes"
    (not (View_base.older_journals_visible_ nested))

let journal_section_markers_preserve_boundaries_and_stable_pages () =
  let unsectioned =
    {
      (journal_outline_row "draft" "" "Draft" "" 0 0) with
      Model.journal_title = None;
      journal_day = None;
    }
  in
  let first_root =
    journal_outline_row "day-a-root" "page-a" "First" "August 27th" 20260827
      0
  in
  let first_child =
    journal_outline_row "day-a-child" "page-a" "Child" "August 27th"
      20260827 1
  in
  let second_root =
    journal_outline_row "day-b-root" "page-b" "Second" "August 28th"
      20260828 0
  in
  let markers =
    Model.journal_section_markers
      [ unsectioned; first_root; first_child; second_root ]
  in
  check_eq ~msg:"only the first row of each journal starts a section"
    (List.map (fun marker -> marker.Model.block_id) markers)
    [ "day-a-root"; "day-b-root" ];
  check_eq ~msg:"journal navigation keeps the page identity"
    (List.map (fun marker -> marker.Model.page_id) markers)
    [ "page-a"; "page-b" ];
  check_eq ~msg:"only later journal sections receive a divider"
    (List.map (fun marker -> marker.Model.has_divider) markers)
    [ false; true ]

let journal_section_markers_recompute_after_row_splices () =
  let day_a =
    journal_outline_row "day-a" "page-a" "A" "August 27th" 20260827 0
  in
  let day_b =
    journal_outline_row "day-b" "page-b" "B" "August 28th" 20260828 0
  in
  let day_c =
    journal_outline_row "day-c" "page-c" "C" "August 29th" 20260829 0
  in
  let initial =
    Model.update (Model.initial ())
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           graph_name = Some "Work";
           selected_graph_id = Some "graph-a";
           has_older_journals = true;
           outliner_rows = [ day_a; day_c ];
         })
  in
  let splice =
    {
      Model.splice_start = Some 1;
      after_block_id = None;
      before_block_id = None;
      delete_count = 0;
      splice_rows = [ day_b ];
    }
  in
  let updated =
    Model.update initial
      (Model.ApplyCoreSnapshot
         {
           (empty_core_projection ()) with
           is_outliner_patch = true;
           outliner_row_splices = [ splice ];
         })
  in
  check_eq ~msg:"splice application recomputes all journal boundaries"
    (List.map (fun marker -> marker.Model.page_id)
       updated.outliner_section_markers)
    [ "page-a"; "page-b"; "page-c" ];
  check_eq ~msg:"inserted sections keep exactly one divider per boundary"
    (List.map (fun marker -> marker.Model.has_divider)
       updated.outliner_section_markers)
    [ false; true; true ];
  check_eq ~msg:"outliner patches preserve the selected graph"
    updated.selected_graph_id (Some "graph-a");
  check_eq ~msg:"outliner patches preserve the graph title"
    updated.selected_graph (Some "Work");
  check ~msg:"outliner patches preserve journal pagination state"
    updated.has_older_journals

let journal_home_keeps_first_day_viewport_and_later_block_items_flat () =
  let application = App.create (ios_backend ()) in
  let day_a =
    journal_outline_row "day-a" "page-a" "A" "August 27th" 20260827 0
  in
  let day_b =
    journal_outline_row "day-b" "page-b" "B" "August 28th" 20260828 0
  in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "test-graph";
         outliner_rows = [ day_a; day_b ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let horizontal_inset =
    descendant_with_identifier renderer root
      "layout.outliner.horizontal-inset"
  in
  let first_heading =
    descendant_with_identifier renderer root "button.journal.page-a"
  in
  let second_heading =
    descendant_with_identifier renderer root "button.journal.page-b"
  in
  let first_section =
    descendant_with_identifier renderer outliner "outliner.window"
  in
  let first_entry =
    parent_with_child_identifier renderer outliner "outliner.block.day-a"
  in
  let second_entry =
    parent_with_child_identifier renderer outliner "outliner.block.day-b"
  in
  let first_entry_children = children renderer first_entry in
  let first_block =
    descendant_with_identifier renderer first_entry "outliner.block.day-a"
  in
  let heading_children = children renderer first_heading in
  let heading_surface =
    if heading_children = [] then -1 else List.nth heading_children 0
  in
  let heading_surface_children =
    if heading_surface = -1 then [] else children renderer heading_surface
  in
  let heading_top_space =
    if heading_surface_children = [] then -1
    else List.nth heading_surface_children 0
  in
  let heading_content =
    if List.length heading_surface_children < 2 then -1
    else List.nth heading_surface_children 1
  in
  check_eq
    ~msg:"journal content is inset inside the full-width scroll surface"
    (property_int renderer first_entry Lui_protocol.PaddingHorizontal)
    8;
  check_eq ~msg:"the scroll indicator reaches the screen edge"
    (property_int renderer horizontal_inset Lui_protocol.PaddingHorizontal)
    (-1);
  check_eq ~msg:"the native virtual list does not add vertical padding"
    (property_int renderer outliner Lui_protocol.PaddingValue)
    (-1);
  check ~msg:"the first journal heading is visible" (first_heading <> -1);
  check ~msg:"the second journal heading is visible" (second_heading <> -1);
  check_eq
    ~msg:"journal headings announce their title without an open action"
    (property_string renderer heading_content Lui_protocol.TextValue)
    "August 27th";
  check ~msg:"the first day's row stays inside the virtualized collection"
    (descendant_with_identifier renderer outliner "outliner.block.day-a"
    <> -1);
  check ~msg:"the second day's row stays inside the virtualized collection"
    (descendant_with_identifier renderer outliner "outliner.block.day-b"
    <> -1);
  check_eq ~msg:"journal rows share one bounded native row source"
    (node renderer first_section)
    (Some Lui_protocol.ListContainer);
  check_eq ~msg:"later journal blocks keep independent lazy entries"
    (node renderer second_entry)
    (Some Lui_protocol.Column);
  check_eq ~msg:"the first block entry owns the journal heading"
    (List.nth first_entry_children 0) first_heading;
  check_eq ~msg:"the journal block follows its heading in one lazy item"
    (List.nth first_entry_children 1) first_block;
  let metadata = Lui_protocol.data_attrs_decode
    (property_string renderer first_section Lui_protocol.DataAttrs) in
  check_eq ~msg:"the native collection fills the viewport after the first journal"
    (List.assoc "data-first-section-count" metadata) "1";
  check_eq ~msg:"viewport retention leaves room for native chrome"
    (List.assoc "data-first-section-inset" metadata) "136";
  check_eq ~msg:"later journal blocks use their intrinsic height"
    (property_string renderer second_entry
       Lui_protocol.ContainerRelativeFrameValue)
    "<missing>";
  check_eq ~msg:"journal headings are noninteractive content"
    (node renderer first_heading)
    (Some Lui_protocol.Box);
  check_eq ~msg:"the interactive heading row does not add a native inset"
    (property_int renderer first_heading Lui_protocol.PaddingValue)
    0;
  check_eq ~msg:"journal heading spacing is owned by one intrinsic surface"
    (if heading_surface = -1 then None else node renderer heading_surface)
    (Some Lui_protocol.Box);
  check_eq ~msg:"journal titles keep main's inner horizontal inset"
    (property_int renderer heading_surface Lui_protocol.PaddingHorizontal)
    8;
  check_eq ~msg:"journal titles keep main's bottom inset"
    (property_int renderer heading_surface Lui_protocol.PaddingVertical)
    12;
  check_eq ~msg:"journal titles express their extra top inset as layout"
    (if heading_top_space = -1 then None
     else node renderer heading_top_space)
    (Some Lui_protocol.Box);
  check_eq
    ~msg:"journal title top spacing completes main's 26-point inset"
    (property_int renderer heading_top_space Lui_protocol.HeightValue)
    14;
  check_eq ~msg:"journal titles retain semantic heading typography"
    (if heading_content = -1 then None else node renderer heading_content)
    (Some Lui_protocol.Heading);
  check_eq ~msg:"journal titles map main's title2 scale"
    (property_int renderer heading_content Lui_protocol.HeadingLevel)
    3;
  check ~msg:"the loaded journal graph keeps main's readiness contract"
    (descendant_with_identifier renderer root "journals.graph-loaded"
    <> -1);
  check_eq ~msg:"later journal sections render main's native divider"
    (descendant_count_with_identifier renderer root "journal.divider")
    1;
  check_eq ~msg:"the first journal block keeps its navigation action"
    (Yojson.Basic.Util.member "journalBullet" (native_row_payload application first_block))
    (`Bool false);
  check_eq ~msg:"journal heading and bullet taps do not open a page"
    (App.model application).pending_effects []

let journal_rows_stay_flat_while_retaining_the_first_viewport () =
  let application = App.create (ios_backend ()) in
  let day_a_root =
    journal_outline_row "day-a-root" "page-a" "A" "August 27th" 20260827 0
  in
  let day_a_child =
    journal_outline_row "day-a-child" "page-a" "Child" "August 27th"
      20260827 1
  in
  let day_b =
    journal_outline_row "day-b" "page-b" "B" "August 28th" 20260828 0
  in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         selected_graph_id = Some "test-graph";
         outliner_rows = [ day_a_root; day_a_child; day_b ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let first_section =
    descendant_with_identifier renderer outliner "outliner.window"
  in
  let first_entry =
    parent_with_child_identifier renderer outliner "outliner.block.day-a-root"
  in
  let child_entry =
    parent_with_child_identifier renderer outliner
      "outliner.block.day-a-child"
  in
  let next_entry =
    parent_with_child_identifier renderer outliner "outliner.block.day-b"
  in
  check ~msg:"blocks from one large journal remain independent lazy items"
    (first_entry <> child_entry);
  check ~msg:"journal boundaries do not change block-level virtualization"
    (child_entry <> next_entry);
  check_eq ~msg:"the first block entry owns its journal heading"
    (node renderer first_entry)
    (Some Lui_protocol.Column);
  check_eq ~msg:"first-journal blocks keep independent entry wrappers"
    (node renderer child_entry)
    (Some Lui_protocol.Column);
  check_eq ~msg:"only the first block repeats the journal heading"
    (descendant_with_identifier renderer child_entry
       "button.journal.page-a")
    (-1);
  let metadata = Lui_protocol.data_attrs_decode
    (property_string renderer first_section Lui_protocol.DataAttrs) in
  check_eq ~msg:"the first journal's two rows determine its viewport fill boundary"
    (List.assoc "data-first-section-count" metadata) "2";
  check ~msg:"all journal rows use the same bounded source"
    (List.for_all (fun entry ->
       List.exists (fun item -> List.mem entry (children renderer item))
         (children renderer first_section)) [first_entry; child_entry; next_entry]);
  check_eq ~msg:"later journals do not create nested section containers"
    (descendant_with_identifier renderer outliner "journal.section.page-b")
    (-1);
  check_eq ~msg:"later journal blocks remain intrinsic lazy entries"
    (property_string renderer next_entry
       Lui_protocol.ContainerRelativeFrameValue)
    "<missing>"

let selected_pages_do_not_render_journal_home_headings () =
  let application = App.create (ios_backend ()) in
  let row =
    journal_outline_row "day-a" "page-a" "A" "August 27th" 20260827 0
  in
  let selected_sidebar =
    {
      (empty_sidebar_projection ()) with
      Model.selected_page =
        Some { Model.uuid = "page-a"; title = "August 27th" };
    }
  in
  start application;
  send application
    (Model.ApplyCoreSnapshot
       {
         (empty_core_projection ()) with
         sidebar = selected_sidebar;
         outliner_rows = [ row ];
       });
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  check_eq
    ~msg:"journal navigation headings stay specific to journal home"
    (descendant_with_identifier renderer root "button.journal.page-a")
    (-1)

let search_navigation_is_isolated_and_cleared_with_the_presentation () =
  let open_model = Model.update (Model.initial ()) Model.OpenSearch in
  let app_model =
    Model.update open_model (Model.RequestAppNode "journal")
  in
  let search_model =
    Model.update app_model (Model.RequestSearchNode "search-result")
  in
  let failed_model =
    Model.update search_model
      (Model.ResolveSearchNode ("search-result", false))
  in
  let reopened_model =
    Model.update
      (Model.update failed_model (Model.RequestSearchNode "search-result"))
      (Model.ChangeSearchQuery "project alpha")
  in
  let closed_model = Model.update reopened_model Model.CloseSearch in
  check_eq ~msg:"search navigation does not mutate the app path"
    search_model.app_navigation_path
    [ Model.NodeRoute "journal" ];
  check_eq ~msg:"search owns a separate navigation path"
    search_model.search_navigation_path
    [ Model.NodeRoute "search-result" ];
  check_eq ~msg:"a failed search route is removed"
    failed_model.search_navigation_path [];
  check_eq ~msg:"closing search clears its navigation history"
    closed_model.search_navigation_path [];
  check_eq
    ~msg:"closing search closes every core-backed search route from the top"
    closed_model.pending_effects
    [
      Model.OpenAppNodeEffect (1, "journal");
      Model.OpenSearchNodeEffect (2, "search-result");
      Model.OpenSearchNodeEffect (3, "search-result");
      Model.CloseSearchNodeEffect (5, "search-result");
    ];
  check_eq ~msg:"closing search preserves the app navigation history"
    closed_model.app_navigation_path
    [ Model.NodeRoute "journal" ];
  check_eq ~msg:"closing search clears its transient query"
    closed_model.search_query ""

let search_query_publishes_a_core_effect_and_rejects_stale_results () =
  let queried =
    Model.update (Model.initial ())
      (Model.ChangeSearchQuery "project alpha")
  in
  let hit =
    {
      Model.hit_uuid = "page-a";
      hit_title = "Project Alpha";
      breadcrumb = "";
      breadcrumbs = [];
      is_page = true;
    }
  in
  let stale =
    Model.update queried
      (Model.ApplySearchResults ("older", [ hit ]))
  in
  let current =
    Model.update queried
      (Model.ApplySearchResults ("project alpha", [ hit ]))
  in
  check_eq ~msg:"typing publishes one typed search request"
    queried.pending_effects
    [ Model.SearchNodesEffect (1, "project alpha") ];
  check ~msg:"the query visibly remains in progress"
    queried.search_loading;
  check_eq ~msg:"a response for an older query is ignored"
    stale.search_results [];
  check_eq ~msg:"the current query accepts its projected hits"
    current.search_results [ hit ];
  check ~msg:"the current result ends the loading state"
    (not current.search_loading)

let search_results_render_as_keyed_native_rows () =
  let application = App.create (ios_backend ()) in
  let hit =
    {
      Model.hit_uuid = "block-a";
      hit_title = "Project note";
      breadcrumb = "Journal › Parent";
      breadcrumbs = [];
      is_page = false;
    }
  in
  start application;
  send application (Model.SelectGraph "Work");
  send application Model.OpenSearch;
  send application (Model.ChangeSearchQuery "project");
  send application (Model.ApplySearchResults ("project", [ hit ]));
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let search_panel = child_with_identifier renderer root "screen.search" in
  let row =
    descendant_with_identifier renderer search_panel "search.result.block-a"
  in
  check_eq ~msg:"the row keeps main's stable search result identifier"
    (property_string renderer row Lui_protocol.AccessibilityIdentifier)
    "search.result.block-a";
  check_eq
    ~msg:"block search results have no bullet or reserved icon space"
    (property renderer row Lui_protocol.InlineIconName)
    None;
  let title =
    descendant_with_identifier renderer row "search.result.title.block-a"
  in
  let context =
    descendant_with_identifier renderer row
      "search.result.context.block-a"
  in
  check_eq
    ~msg:"result previews emphasize matches and bound multiline content"
    (property_string renderer title Lui_protocol.StyleClass)
    "search-match line-clamp-3";
  check_eq ~msg:"result ancestry uses a compact secondary line"
    (property_string renderer context Lui_protocol.StyleClass)
    "caption single-line";
  check_eq ~msg:"result ancestry is visually distinct from the matching text"
    (property_string renderer context Lui_protocol.ForegroundValue)
    "muted-foreground";
  dispatch application (Lui_protocol.Press row);
  flush application;
  check_eq ~msg:"pressing a result requests navigation in LG state"
    (App.model application).search_navigation_path
    [ Model.NodeRoute "block-a" ]

let search_renders_main_empty_states_and_result_sections () =
  let application = App.create (ios_backend ()) in
  let page =
    {
      Model.hit_uuid = "page-a";
      hit_title = "Project";
      breadcrumb = "";
      breadcrumbs = [];
      is_page = true;
    }
  in
  let block =
    {
      Model.hit_uuid = "block-a";
      hit_title = "Project note";
      breadcrumb = "Journal";
      breadcrumbs = [];
      is_page = false;
    }
  in
  start application;
  send application (Model.SelectGraph "Work");
  send application Model.OpenSearch;
  flush application;
  let renderer = Lui_app.runtime application in
  let panel =
    child_with_identifier renderer (main_root renderer application)
      "screen.search"
  in
  let empty_state =
    descendant_with_identifier renderer panel "search.empty"
  in
  let empty_icon =
    descendant_with_identifier renderer panel "search.empty.icon"
  in
  let empty_supporting =
    descendant_with_identifier renderer panel "search.empty.supporting"
  in
  check_eq ~msg:"native search content fills the presentation viewport"
    (property_float renderer panel Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"an empty query explains the search entry state"
    (property_string renderer empty_state Lui_protocol.TextValue)
    "Search your graph";
  check_eq ~msg:"search empty states use the shared search icon"
    (node renderer empty_icon)
    (Some Lui_protocol.Icon);
  check_eq ~msg:"search empty states explain what can be found"
    (property_string renderer empty_supporting Lui_protocol.TextValue)
    "Find pages and blocks by title or content.";
  send application (Model.ChangeSearchQuery "missing");
  flush application;
  check ~msg:"pending queries show progress before any results are available"
    (descendant_with_identifier renderer panel "search.loading" <> -1);
  check_eq ~msg:"a pending query must not flash a false no-results state"
    (descendant_with_identifier renderer panel "search.empty")
    (-1);
  send application (Model.ApplySearchResults ("missing", []));
  flush application;
  check_eq
    ~msg:"an empty result set is distinguished from an empty query"
    (property_string renderer
       (descendant_with_identifier renderer panel "search.empty")
       Lui_protocol.TextValue)
    "No results";
  send application (Model.ChangeSearchQuery "project");
  send application (Model.ApplySearchResults ("project", [ block; page ]));
  flush application;
  check
    ~msg:
      "search results use a native list surface for safe-area and \
       scrolling behavior"
    (descendant_with_identifier renderer panel "screen.search.results"
    <> -1);
  check ~msg:"page results have the main section label"
    (descendant_with_identifier renderer panel "search.section.pages"
    <> -1);
  check ~msg:"block results have the main section label"
    (descendant_with_identifier renderer panel "search.section.blocks"
    <> -1);
  check ~msg:"page results remain addressable"
    (descendant_with_identifier renderer panel "search.result.page-a"
    <> -1);
  check ~msg:"block results remain addressable"
    (descendant_with_identifier renderer panel "search.result.block-a"
    <> -1)

let native_search_clear_updates_lg_owned_query () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  send application Model.OpenSearch;
  send application (Model.ChangeSearchQuery "project");
  flush application;
  let search_extension =
    extension_node application "native-search-presentation"
  in
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( search_extension,
         "native-search-presentation",
         "query-changed",
         Lui_protocol.String_map.singleton "query"
           (Lui_protocol.StringValue "") ));
  flush application;
  check_eq ~msg:"the platform clear affordance updates LG state"
    (App.model application).search_query ""

let core_snapshot_renders_keyed_outliner_rows () =
  let application = App.create (ios_backend ()) in
  let row =
    {
      (outline_row "block-a" "Project note") with
      Model.depth = 2;
      has_children = true;
    }
  in
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Project note";
      caret_utf16_offset = 4;
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] true "" [] []
       (Some editing) None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let rendered_row =
    descendant_with_identifier renderer outliner "outliner.block.block-a"
  in
  check_eq ~msg:"rows retain their stable block identifier"
    (property_string renderer rendered_row Lui_protocol.AccessibilityIdentifier)
    "outliner.block.block-a";
  let payload = native_row_payload application rendered_row in
  check_eq (Yojson.Basic.Util.member "uuid" payload) (`String "block-a");
  check_eq (Yojson.Basic.Util.member "depth" payload) (`Int 2);
  check_eq (Yojson.Basic.Util.member "title" payload) (`String "Project note");
  let editor =
    descendant_with_extension renderer application rendered_row
      "outliner-editor"
  in
  check_eq ~msg:"editing uses the registered native editor service"
    (extension_kind renderer editor)
    (Some "outliner-editor");
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( editor,
         "outliner-editor",
         "text-change",
         Lui_protocol.String_map.empty
         |> Lui_protocol.String_map.add "title"
              (Lui_protocol.StringValue "Updated")
         |> Lui_protocol.String_map.add "caret-utf16-offset"
              (Lui_protocol.IntValue 7) ));
  flush application;
  check_eq ~msg:"native editor events return to the typed LG reducer"
    (App.model application).pending_effects
    [ Model.ChangeOutlinerTextEffect (1, "block-a", "Updated", 7) ];
  check_eq ~msg:"typing hides stale synced state immediately"
    (App.model application).sync_state Model.SyncingState

let outliner_rows_live_inside_a_native_virtual_list () =
  let application = App.create (ios_backend ()) in
  start application;
  send application (Model.SelectGraph "Work");
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let list_node =
    descendant_with_identifier renderer root "list.outliner"
  in
  let horizontal_inset =
    descendant_with_identifier renderer root
      "layout.outliner.horizontal-inset"
  in
  check_eq ~msg:"journal blocks use one native lazy scrolling collection"
    (node renderer list_node)
    (Some Lui_protocol.VirtualList);
  check_eq ~msg:"the journal collection owns the remaining viewport"
    (property_float renderer list_node Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"the scrolling surface has no outer inset"
    (property_int renderer horizontal_inset Lui_protocol.PaddingHorizontal)
    (-1);
  check_eq ~msg:"the journal collection does not add a vertical inset"
    (property_int renderer list_node Lui_protocol.PaddingVertical)
    (-1);
  check_eq ~msg:"journal content starts at main's native outliner inset"
    (property_int renderer (List.nth (children renderer list_node) 0)
       Lui_protocol.HeightValue)
    16;
  check_eq ~msg:"the virtual list does not retain a redundant scroll wrapper"
    (descendant_with_identifier renderer root "scroll.outliner")
    (-1)

let thousand_nested_rows () =
  List.init 1_000 (fun index ->
    { (outline_row ("large-" ^ string_of_int index) "Nested block") with
      Model.depth = index mod 4;
      has_children = index mod 4 < 3 })

let check_flat_lazy_rows renderer collection rows =
  check_eq ~msg:"the collection owns one native lazy scrolling surface"
    (node renderer collection) (Some Lui_protocol.VirtualList);
  let identifiers = Hashtbl.create (List.length rows) in
  List.iter (fun (row : Model.outline_row) ->
    Hashtbl.replace identifiers ("outliner.block." ^ row.row_uuid) ()) rows;
  let rec count_rows id =
    let own = if Hashtbl.mem identifiers
      (property_string renderer id Lui_protocol.AccessibilityIdentifier)
      then 1 else 0 in
    List.fold_left (fun count child -> count + count_rows child) own
      (children renderer id)
  in
  let items = List.fold_left (fun result child ->
    if property_string renderer child Lui_protocol.AccessibilityIdentifier = "outliner.window" then
      List.rev_append (children renderer child) result
    else child :: result) [] (children renderer collection) |> List.rev in
  let counts = List.map count_rows items in
  check ~msg:"every block, including nested children, is an independent lazy item"
    (List.for_all (fun count -> count <= 1) counts);
  check ~msg:"only the initial native window is materialized"
    (let mounted = List.fold_left (+) 0 counts in mounted > 0 && mounted <= 32);
  let window = descendant_with_identifier renderer collection "outliner.window" in
  let attributes = Lui_protocol.data_attrs_decode
    (property_string renderer window Lui_protocol.DataAttrs) in
  check ~msg:"the native collection retains the complete scrollable row count"
    (int_of_string (List.assoc "data-virtual-count" attributes) >= List.length rows)

let large_node_pages_virtualize_each_nested_block () =
  let application = App.create (ios_backend ()) in
  let rows = thousand_nested_rows () in
  let route = { (node_projection "page-a" "page-a" "Large page" [] []) with
    Model.node_outliner_rows = rows } in
  start application;
  send application (Model.RequestAppNode "page-a");
  send application (apply_core_snapshot None (empty_sidebar_projection ()) []
    false "" [] [ route ] None None [] [] rows false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let screen = descendant_with_identifier renderer
    (Lui_app.root_node application) "screen.node" in
  let collection = descendant_with_identifier renderer screen "list.outliner" in
  check_flat_lazy_rows renderer collection rows

let large_tag_and_reference_sections_virtualize_each_block () =
  List.iter (fun is_tag ->
    let application = App.create (ios_backend ()) in
    let rows = thousand_nested_rows () in
    let sidebar = { (empty_sidebar_projection ()) with
      Model.selected_page = Some { Model.uuid = "page-a"; title = "Large page" };
      selected_page_is_tag = is_tag;
      related_rows = rows } in
    start application;
    send application (apply_core_snapshot None sidebar [] false "" [] [] None
      None [] [] [] false []);
    flush application;
    let renderer = Lui_app.runtime application in
    let collection = descendant_with_identifier renderer
      (main_root renderer application) "list.outliner" in
    check_flat_lazy_rows renderer collection rows
  ) [ false; true ]

let ten_thousand_blocks_mount_only_the_requested_window () =
  List.iter (fun destination ->
    let application = App.create (ios_backend ()) in
    let rows = List.init 10_000 (fun index ->
      { (outline_row ("window-" ^ string_of_int index) "Nested block") with
        Model.depth = index mod 4; has_children = index mod 4 < 3;
        page_id = "page-a"; journal_title = Some "Journal"; journal_day = Some 20261019 }) in
    let page = { Model.uuid = "page-a"; title = "Large page" } in
    let sidebar = { (empty_sidebar_projection ()) with
      Model.selected_page = (if destination = "journals" then None else Some page); selected_page_is_tag = destination = "tag";
      related_rows = if (destination = "tag" || destination = "mixed") then rows else [] } in
    let routes = if destination = "node" then
      [{ (node_projection "page-a" "page-a" "Large page" [] []) with
          Model.node_outliner_rows = rows }] else [] in
    start application;
    if destination = "node" then send application (Model.RequestAppNode "page-a");
    send application (apply_core_snapshot None sidebar [] false "" [] routes None
      None [] [] (if destination = "tag" then [] else if destination = "mixed" then thousand_nested_rows () else rows) false []);
    flush application;
    let renderer = Lui_app.runtime application in
    let root () = if destination = "node" then
      descendant_with_identifier renderer (Lui_app.root_node application) "screen.node"
      else main_root renderer application in
    let count_rows () =
      let rec loop id =
        (if extension_kind renderer id = Some "outliner-block-row" then 1 else 0)
        + List.fold_left (fun count child -> count + loop child) 0 (children renderer id)
      in loop (root ()) in
    check ~msg:"10k rows must not create 10k protocol subtrees" (count_rows () <= 32);
    check ~msg:"the initial window contains actual blocks" (count_rows () > 0);
    let window = descendant_with_identifier renderer (root ()) "outliner.window" in
    check ~msg:"the collection exposes a bounded row source" (window <> -1);
    dispatch application (Lui_protocol.VisibleRange (window, (if destination = "mixed" then 10_980 else 9_980), (if destination = "mixed" then 10_999 else 9_999)));
    flush application;
    check ~msg:"scrolling can reach the final nested block"
      (descendant_with_identifier renderer (root ()) "outliner.block.window-9999" <> -1);
    check ~msg:"scrolling evicts distant row subtrees" (count_rows () <= 32);
    check_eq ~msg:"rows far above the viewport are unmounted"
      (descendant_with_identifier renderer (root ()) (if destination = "mixed" then "outliner.block.large-0" else "outliner.block.window-0")) (-1);
    dispatch application (Lui_protocol.VisibleRange (window, 0, 19));
    flush application;
    check ~msg:"scrolling back restores the first block"
      (descendant_with_identifier renderer (root ()) (if destination = "mixed" then "outliner.block.large-0" else "outliner.block.window-0") <> -1);
    check ~msg:"the window stays bounded after reverse scrolling" (count_rows () <= 32)
  ) ["root"; "node"; "tag"; "mixed"; "journals"]

let distant_outline_contents_are_loaded_without_replacing_the_page () =
  List.iter (fun is_tag ->
    let application = App.create (ios_backend ()) in
    let rows = List.init 10_000 (fun index ->
      { (outline_row ("content-" ^ string_of_int index) (if index < 32 then "Loaded" else "")) with
        Model.row_loaded = index < 32; depth = index mod 4;
        has_children = index mod 4 < 3 }) in
    let projection = { (empty_core_projection ()) with
      Model.graph_name = Some "Work"; selected_graph_id = Some "graph";
      sidebar = { (empty_sidebar_projection ()) with
        selected_page = Some { Model.uuid = "page"; title = "Large page" };
        selected_page_is_tag = is_tag; related_rows = if is_tag then rows else [] };
      outliner_rows = if is_tag then [] else rows } in
    start application;
    send application (Model.ApplyCoreSnapshot projection);
    flush application;
    let renderer = Lui_app.runtime application in
    let root () = main_root renderer application in
    let window = descendant_with_identifier renderer (root ()) "outliner.window" in
    dispatch application (Lui_protocol.VisibleRange (window, 9_980, 9_999));
    flush application;
    let requested = List.concat_map (function
      | Model.HydrateOutlinerRowsEffect (_, ids) -> ids | _ -> []) (App.model application).pending_effects in
    check ~msg:"scrolling requests only the missing content window"
      (List.length requested > 0 && List.length requested <= 32);
    check ~msg:"the final nested block is included in the content request" (List.mem "content-9999" requested);
    let content = List.map (fun id -> { (outline_row id "Hydrated block") with Model.row_loaded = true }) requested in
    send application (Model.ApplyCoreSnapshot { (empty_core_projection ()) with
      Model.selected_graph_id = Some "graph"; is_outliner_content_patch = true; hydrated_rows = content });
    flush application;
    let current = App.model application in
    let final_rows = if is_tag then current.related_rows else current.outliner_rows in
    check_eq ~msg:"content patches retain the complete outline topology" (List.length final_rows) 10_000;
    let last = List.nth final_rows 9_999 in
    check_eq last.row_title "Hydrated block";
    check_eq ~msg:"hydration preserves nested indentation" last.depth 3;
    check ~msg:"hydrated content becomes available to the mounted row" last.row_loaded;
    check_eq ~msg:"content-only patches preserve graph and page selection" current.selected_graph_id (Some "graph");
    check ~msg:"the final block renders after hydration"
      (descendant_with_identifier renderer (root ()) "outliner.block.content-9999" <> -1)
  ) [false; true]

let returning_to_a_scrolled_page_keeps_hydrated_rows_mounted () =
  let application = App.create (ios_backend ()) in
  let rows = List.init 96 (fun index -> outline_row
    ("return-" ^ string_of_int index) ("Cached block " ^ string_of_int index)) in
  let shells = List.mapi (fun index row -> if index < 32 then row else
    { row with Model.row_title = ""; markup_json = "[]"; row_loaded = false }) rows in
  let root = { (empty_core_projection ()) with
    Model.graph_name = Some "Work"; selected_graph_id = Some "graph";
    sidebar = { (empty_sidebar_projection ()) with
      selected_page = Some { Model.uuid = "page"; title = "Long page" };
      related_rows = [outline_row "linked-ref" "Linked reference"] };
    outliner_rows = rows; journal_outliner_rows = shells } in
  start application;
  send application (Model.ApplyCoreSnapshot root);
  flush application;
  let renderer = Lui_app.runtime application in
  let page_root () = descendant_with_identifier renderer (main_root renderer application) "pane.selected-page" in
  let window = descendant_with_identifier renderer (page_root ()) "outliner.window" in
  dispatch application (Lui_protocol.VisibleRange (window, 64, 79));
  flush application;
  let mounted = descendant_with_identifier renderer (page_root ()) "outliner.block.return-70" in
  check ~msg:"the distant block is mounted before following a page link" (mounted <> -1);
  send application (Model.RequestAppNode "tag");
  send application (Model.ApplyCoreSnapshot { root with
    Model.outliner_rows = []; sidebar = { root.sidebar with related_rows = [] };
    pending_reference_uuid = Some "tag";
    node_routes = [{ (node_projection "tag" "tag" "Tag" [] []) with Model.node_is_tag = true }] });
  flush application;
  check_eq ~msg:"the covered page keeps linked references while another node is active"
    (List.map (fun row -> row.Model.row_uuid) (App.model application).related_rows) ["linked-ref"];
  send application (Model.BackAppNavigation 1);
  send application (Model.ApplyCoreSnapshot { root with Model.outliner_rows = shells;
    sidebar = { root.sidebar with related_rows = [] }; pending_reference_uuid = Some "page" });
  flush application;
  check_eq ~msg:"returning preserves the hydrated visible block without an empty frame"
    (descendant_with_identifier renderer (page_root ()) "outliner.block.return-70") mounted;
  check_eq ~msg:"returning preserves the same collection and its scroll position"
    (descendant_with_identifier renderer (page_root ()) "outliner.window") window;
  check_eq ~msg:"cached distant content stays available while refreshing"
    (List.nth (App.model application).outliner_rows 70).row_title "Cached block 70";
  check_eq ~msg:"references do not disappear while the returned page refreshes them"
    (List.map (fun row -> row.Model.row_uuid) (App.model application).related_rows) ["linked-ref"];
  send application (Model.ApplyCoreSnapshot { (empty_core_projection ()) with
    Model.selected_graph_id = Some "graph"; reference_update = Some ("page", []) });
  flush application;
  check_eq ~msg:"an authoritative empty reference response still removes deleted references"
    (App.model application).related_rows []

let search_only_patches_preserve_the_open_outline () =
  let current = { (Model.initial ()) with Model.selected_graph_id = Some "graph";
    search_query = "latest"; search_loading = true;
    outliner_rows = [outline_row "kept" "Keep this block"] } in
  let hit = { Model.hit_uuid = "result"; hit_title = "Result"; breadcrumb = ""; breadcrumbs = []; is_page = true } in
  let projection = { (empty_core_projection ()) with Model.is_search_patch = true;
    selected_graph_id = Some "graph"; projection_search_query = "latest"; search_results = [hit] } in
  let updated = Model.update current (Model.ApplyCoreSnapshot projection) in
  check_eq updated.outliner_rows current.outliner_rows;
  check_eq updated.selected_graph_id current.selected_graph_id;
  check_eq updated.search_results [hit];
  let stale = Model.update updated (Model.ApplyCoreSnapshot {projection with Model.projection_search_query = "older"; search_results = []}) in
  check_eq ~msg:"late search responses cannot replace the latest results" stale.search_results [hit]

let selected_page_waits_for_blocks_before_showing_empty_state () =
  List.iter (fun cached ->
    let application = App.create (ios_backend ()) in
    let page = { Model.uuid = "page-a"; title = "Project" } in
    let rows = if cached then
      [{ (outline_row "cached" "Cached content") with Model.page_id = "page-a";
         journal_title = Some "Project"; journal_day = Some 20261019 }] else [] in
    let sidebar = { (empty_sidebar_projection ()) with Model.recent_pages = [page] } in
    start application;
    send application (apply_core_snapshot None sidebar [] false "" [] [] None
      None [] [] rows false []);
    send application (Model.SelectSidebarPage "page-a");
    flush application;
    let renderer = Lui_app.runtime application in
    let root = main_root renderer application in
    check_eq ~msg:"unresolved pages never pretend to be empty"
      (descendant_with_identifier renderer root "button.outliner.add-first-block") (-1);
    check_eq ~msg:"only uncached pages show their loading state"
      (descendant_with_identifier renderer root "status.page-loading" <> -1) (not cached);
    let selected = { sidebar with Model.selected_page = Some page } in
    send application (apply_core_snapshot None selected [] false "" [] [] None
      None [] [] [] false []);
    flush application;
    check ~msg:"confirmed empty pages expose Add first block"
      (descendant_with_identifier renderer (main_root renderer application)
         "button.outliner.add-first-block" <> -1);
    check_eq ~msg:"the authoritative empty response finishes loading"
      (descendant_with_identifier renderer (main_root renderer application)
         "status.page-loading") (-1)
  ) [false; true]

let reselecting_the_current_page_preserves_loaded_rows () =
  List.iter (fun is_tag ->
    let application = App.create (ios_backend ()) in
    let page = { Model.uuid = "page-a"; title = "Project" } in
    let rows = thousand_nested_rows () in
    let sidebar = { (empty_sidebar_projection ()) with
      Model.favorites = [ page ]; selected_page = Some page;
      selected_page_is_tag = is_tag;
      related_rows = if is_tag then rows else [] } in
    start application;
    send application (apply_core_snapshot None sidebar [] false "" [] [] None
      None [] [] (if is_tag then [] else rows) false []);
    flush application;
    let renderer = Lui_app.runtime application in
    let root = main_root renderer application in
    let first = descendant_with_identifier renderer root "outliner.block.large-0" in
    send application Model.OpenSidebar;
    send application (Model.SelectSidebarPage "page-a");
    flush application;
    check_eq ~msg:"reselecting a loaded page retains its block identity during refresh"
      (descendant_with_identifier renderer (main_root renderer application)
         "outliner.block.large-0") first;
    check_eq ~msg:"reselecting a tag keeps its kind and reference rows"
      (App.model application).selected_page_is_tag is_tag;
    check ~msg:"reselecting the already loaded root does not request another full snapshot"
      (not (List.exists (function Model.SelectSidebarPageEffect _ -> true | _ -> false)
        (App.model application).pending_effects));
    check_eq ~msg:"a loaded page never returns to a loading placeholder"
      (descendant_with_identifier renderer (main_root renderer application)
         "status.page-loading") (-1)
  ) [false; true]

let projected_markup_renders_through_the_native_rich_block_extension () =
  let application = App.create (ios_backend ()) in
  let done_status =
    {
      Model.uuid = "done";
      ident = Some "logseq.property/status.done";
      title = "Done";
      icon_type = None;
      icon_id = None;
      icon_color = None;
    }
  in
  let row =
    {
      (outline_row "block-a" "See [[Project]]") with
      Model.markup_json =
        "[{\"type\":\"nodeReference\",\"uuid\":\"page-a\",\"title\":\"Project\"}]";
      has_children = true;
      row_status = Some done_status;
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       None None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let rendered_row =
    descendant_with_identifier renderer outliner "outliner.block.block-a"
  in
  let rich_content = native_row application rendered_row in
  let payload = native_row_payload application rendered_row in
  check_eq ~msg:"completed styling reaches the native row"
    (Yojson.Basic.Util.member "completed" payload) (`Bool true);
  check_eq ~msg:"native rows retain draggable block identity"
    (Yojson.Basic.Util.member "uuid" payload) (`String "block-a");
  check_eq ~msg:"projected links retain their native markup"
    (Yojson.Basic.Util.member "markup" payload)
    (Yojson.Basic.from_string row.markup_json);
  check_eq ~msg:"native disclosure receives child state"
    (Yojson.Basic.Util.member "hasChildren" payload) (`Bool true);
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( rich_content,
         "outliner-block-row",
         "drag-start",
         Lui_protocol.String_map.singleton "uuid"
           (Lui_protocol.StringValue "block-a") ));
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( rich_content,
         "outliner-block-row",
         "drop",
         Lui_protocol.String_map.empty
         |> Lui_protocol.String_map.add "uuid"
              (Lui_protocol.StringValue "target-a")
         |> Lui_protocol.String_map.add "placement"
              (Lui_protocol.StringValue "before") ));
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( rich_content,
         "outliner-block-row",
         "open-node",
         Lui_protocol.String_map.singleton "uuid"
           (Lui_protocol.StringValue "page-a") ));
  dispatch application
    (Lui_protocol.ExtensionEvent
       ( rich_content,
         "outliner-block-row",
         "edit",
         Lui_protocol.String_map.singleton "uuid"
           (Lui_protocol.StringValue "block-a") ));
  flush application;
  check_eq ~msg:"rich node references return to LG-owned navigation"
    (App.model application).app_navigation_path
    [ Model.NodeRoute "page-a" ];
  check_eq ~msg:"native rich-content events return to the typed LG reducer"
    (App.model application).pending_effects
    [
      Model.LongPressOutlinerBlockEffect (1, "block-a");
      Model.DropOutlinerBlocksEffect (2, "target-a", "before");
      Model.OpenAppNodeEffect (3, "page-a");
      Model.TapOutlinerBlockEffect (4, "block-a");
    ]

let projected_assets_render_and_open_through_the_native_extension () =
  let application = App.create (ios_backend ()) in
  let row =
    {
      (outline_row "asset-a" "Photo.jpg") with
      Model.is_asset = true;
      asset_type = Some "image/jpeg";
      local_path = Some "Assets/Photo.jpg";
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       None None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let rendered_row =
    descendant_with_identifier renderer outliner "outliner.block.asset-a"
  in
  let payload = native_row_payload application rendered_row in
  check_eq ~msg:"asset identity reaches the native row"
    (Yojson.Basic.Util.member "isAsset" payload) (`Bool true);
  check_eq ~msg:"asset content type reaches the native preview"
    (Yojson.Basic.Util.member "assetType" payload) (`String "image/jpeg");
  check_eq ~msg:"cached image path reaches the native preview"
    (Yojson.Basic.Util.member "localPath" payload) (`String "Assets/Photo.jpg");
  check_eq ~msg:"mounting images never opens a generic file preview"
    (App.model application).pending_effects []

let outliner_row_press_publishes_a_typed_core_effect () =
  let current = Model.initial () in
  let editing = Model.update current (Model.BeginOutlinerEdit "block-a") in
  check_eq ~msg:"tapBlock crosses the LG effect boundary"
    editing.pending_effects
    [ Model.TapOutlinerBlockEffect (1, "block-a") ];
  check_eq ~msg:"outliner effects share the monotonic effect sequence"
    editing.next_effect_id 2

let kotlin_rich_rows_own_their_primary_tap () =
  let row = outline_row "block-a" "Linked block" in
  check_eq
    ~msg:"Kotlin rich content avoids a competing whole-row primary tap"
    (View_base.outliner_row_list_item_press_enabled_
       Lui_protocol.KotlinHost row)
    false;
  check_eq
    ~msg:"Kotlin asset rows retain their whole-row presentation action"
    (View_base.outliner_row_list_item_press_enabled_
       Lui_protocol.KotlinHost
       { row with Model.is_asset = true })
    true;
  check_eq
    ~msg:"Kotlin page rows retain their whole-row navigation action"
    (View_base.outliner_row_list_item_press_enabled_
       Lui_protocol.KotlinHost
       { row with Model.opens_as_page = true })
    true;
  check_eq
    ~msg:
      "SwiftUI rows keep native list item editing outside the bullet \
       control"
    (View_base.outliner_row_list_item_press_enabled_
       Lui_protocol.SwiftUIHost row)
    true

let active_page_actions_use_typed_core_and_platform_effects () =
  let page = { Model.uuid = "page-a"; title = "Project" } in
  let asset =
    {
      (outline_row "asset-a" "Photo.jpg") with
      Model.is_asset = true;
      asset_type = Some "image/jpeg";
      local_path = Some "Assets/Photo.jpg";
    }
  in
  let current =
    {
      (Model.initial ()) with
      Model.selected_page = Some page;
      outliner_rows = [ asset ];
    }
  in
  let favorited = Model.update current Model.ToggleActivePageFavorite in
  let shared = Model.update favorited Model.ShareActivePage in
  let requested = Model.update shared Model.RequestDeleteActivePage in
  let deleted = Model.update requested Model.ConfirmDeleteActivePage in
  check_eq ~msg:"favorite changes cross the semantic core boundary"
    favorited.pending_effects
    [ Model.SetPageFavoriteEffect (1, "page-a", true) ];
  check_eq
    ~msg:
      "sharing carries rendered text and unique local assets to the \
       platform"
    shared.pending_effects
    [
      Model.SetPageFavoriteEffect (1, "page-a", true);
      Model.PresentPageShareEffect
        (2, "Project\n- Photo.jpg", [ "Assets/Photo.jpg" ]);
    ];
  check_eq ~msg:"page deletion requires explicit confirmation"
    requested.pending_page_deletion (Some page);
  check_eq ~msg:"confirmed deletion recycles the page and leaves its selected route"
    deleted.pending_effects
    [
      Model.SetPageFavoriteEffect (1, "page-a", true);
      Model.PresentPageShareEffect
        (2, "Project\n- Photo.jpg", [ "Assets/Photo.jpg" ]);
      Model.DeletePageEffect (3, "page-a");
      Model.ClearSelectedPageEffect 4;
    ]

let page_delete_dialog_exposes_stable_material_actions () =
  let application = App.create (kotlin_backend ()) in
  let page = { Model.uuid = "page-a"; title = "Project" } in
  let sidebar =
    { (empty_sidebar_projection ()) with Model.selected_page = Some page }
  in
  start application;
  send application
    (apply_core_snapshot None sidebar [] true "" [] [] None None [] [] []
       false []);
  send application Model.RequestDeleteActivePage;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  check ~msg:"the Material confirmation exposes its dialog root"
    (descendant_with_identifier renderer root "dialog.page-delete" <> -1);
  check ~msg:"the Material confirmation exposes an independent cancel action"
    (descendant_with_identifier renderer root "button.page-delete.cancel"
    <> -1);
  check ~msg:"the Material confirmation exposes an independent delete action"
    (descendant_with_identifier renderer root "button.page-delete.confirm"
    <> -1)

let connection_menu_matches_active_page_actions () =
  let application = App.create (ios_backend ()) in
  let page = { Model.uuid = "page-a"; title = "Project" } in
  let sidebar =
    {
      (empty_sidebar_projection ()) with
      Model.favorites = [ page ];
      selected_page = Some page;
    }
  in
  start application;
  send application
    (apply_core_snapshot None sidebar [] true "" [] [] None None [] [] []
       false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let connection =
    descendant_with_identifier renderer navigation "button.connection"
  in
  check ~msg:"active pages expose the native overflow menu"
    (connection <> -1);
  check_eq ~msg:"the native action label reflects favorite state"
    (descendant_count_with_property_string renderer connection
       Lui_protocol.TextValue "Unfavorite")
    1;
  check_eq ~msg:"active pages expose the share action"
    (descendant_count_with_property_string renderer connection
       Lui_protocol.TextValue "Share")
    1;
  check_eq ~msg:"page overflow excludes graph settings"
    (descendant_count_with_property_string renderer connection
       Lui_protocol.TextValue "Settings")
    0;
  dispatch application
    (Lui_protocol.Press
       (menu_item_with_text renderer connection "Unfavorite"));
  flush application;
  check_eq ~msg:"the native favorite action keeps its typed LG event"
    (App.model application).pending_effects
    [ Model.SetPageFavoriteEffect (1, "page-a", false) ]

let outliner_structure_controls_use_native_navigation_and_core_effects () =
  let collapsed =
    Model.update (Model.initial ())
      (Model.ToggleOutlinerCollapsed "parent")
  in
  let zoomed = Model.update collapsed (Model.RequestAppNode "parent") in
  check_eq ~msg:"collapse crosses the LG effect boundary"
    collapsed.pending_effects
    [ Model.ToggleOutlinerCollapsedEffect (1, "parent") ];
  check_eq
    ~msg:"zoom enters the native route through the ordered core effect queue"
    zoomed.pending_effects
    [
      Model.ToggleOutlinerCollapsedEffect (1, "parent");
      Model.OpenAppNodeEffect (2, "parent");
    ];
  check_eq ~msg:"zoom is represented in the native navigation path"
    zoomed.app_navigation_path
    [ Model.NodeRoute "parent" ];
  check_eq ~msg:"both structure controls advance stable effect IDs"
    zoomed.next_effect_id 3

let outliner_task_status_selection_uses_the_core_event_boundary () =
  let todo =
    Model.task_status "todo" "logseq.property/status.todo" "Todo" "Todo"
  in
  let done_status =
    Model.task_status "done" "logseq.property/status.done" "Done" "Done"
  in
  let current =
    { (Model.initial ()) with Model.task_statuses = [ todo; done_status ] }
  in
  let chosen =
    Model.update current (Model.SetOutlinerTaskStatus ("block-a", "done"))
  in
  check_eq
    ~msg:"status changes use one direct typed outliner core boundary"
    chosen.pending_effects
    [ Model.SetOutlinerTaskStatusEffect (1, "block-a", done_status) ]

let kotlin_outliner_markers_match_ios_visual_metrics () =
  let application = App.create (kotlin_backend ()) in
  let todo =
    Model.task_status "todo" "logseq.property/status.todo" "Todo" "Todo"
  in
  let done_status =
    Model.task_status "done" "logseq.property/status.done" "Done" "Done"
  in
  let row =
    {
      (outline_row "block-a" "Ship it") with
      Model.row_status = Some todo;
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] true "" [] []
       None None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let rendered_row =
    descendant_with_identifier renderer root "outliner.block.block-a"
  in
  let bullet =
    descendant_with_identifier renderer rendered_row
      "outliner.bullet-glyph.block-a"
  in
  let zoom_button =
    descendant_with_identifier renderer rendered_row
      "button.outliner.zoom.block-a.Ship it"
  in
  let status_icon =
    descendant_with_identifier renderer rendered_row
      "outliner.task-status-icon.block-a"
  in
  let status_button =
    descendant_with_identifier renderer rendered_row
      "button.block-task-status"
  in
  check
    ~msg:"Kotlin renders a dedicated visual bullet inside its hit target"
    (bullet <> -1);
  check_eq ~msg:"Kotlin uses iOS main's seven-point bullet diameter"
    (property_int renderer bullet Lui_protocol.WidthValue)
    7;
  check_eq ~msg:"the outliner bullet remains circular"
    (property_int renderer bullet Lui_protocol.HeightValue)
    7;
  check_eq ~msg:"the zoom control keeps iOS main's 24-point layout slot"
    (property_int renderer zoom_button Lui_protocol.WidthValue)
    24;
  check_eq ~msg:"the zoom control keeps a stable square interaction slot"
    (property_int renderer zoom_button Lui_protocol.HeightValue)
    24;
  check
    ~msg:"Kotlin renders the task glyph independently from its menu target"
    (status_icon <> -1);
  check_eq ~msg:"Kotlin uses iOS main's 22-point task status glyph"
    (property_int renderer status_icon Lui_protocol.WidthValue)
    22;
  check_eq ~msg:"the task status glyph keeps iOS main's square frame"
    (property_int renderer status_icon Lui_protocol.HeightValue)
    22;
  check_eq ~msg:"Kotlin matches iOS by using the row foreground for Todo"
    (property_string renderer status_icon Lui_protocol.ForegroundValue)
    "foreground";
  check_eq
    ~msg:
      "the transparent zoom target does not re-add a large Material \
       circle"
    (property_string renderer zoom_button Lui_protocol.InlineIconName)
    "<missing>";
  check_eq
    ~msg:"the transparent status target does not duplicate the visible glyph"
    (property_string renderer status_button Lui_protocol.InlineIconName)
    "<missing>";
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] true "" [] []
       None None [] []
       [ { row with Model.row_status = Some done_status } ]
       true []);
  flush application;
  let updated_root = main_root renderer application in
  let updated_row =
    descendant_with_identifier renderer updated_root "outliner.block.block-a"
  in
  let updated_status_icon =
    descendant_with_identifier renderer updated_row
      "outliner.task-status-icon.block-a"
  in
  check_eq
    ~msg:
      "a retained Kotlin row replaces the task glyph when status changes"
    (property_string renderer updated_status_icon Lui_protocol.IconName)
    "app:task-done";
  check_eq
    ~msg:"retained status changes preserve iOS row foreground styling"
    (property_string renderer updated_status_icon
       Lui_protocol.ForegroundValue)
    "foreground"

let ios_rows_use_one_native_layout_and_keep_typed_actions () =
  check_eq (Lui_extension.fingerprint (View.outliner_block_row_schema ()))
    "lui-extension-v1|18:outliner-block-row|profiles:ios/swiftui|standard-children:1|children:|properties:7:payload:string:required:none|events:10:drag-start[4:uuid:string:required],10:long-press[4:uuid:string:required],10:set-status[4:uuid:string:required,5:count:int:required],4:drop[4:uuid:string:required,9:placement:string:required],4:edit[4:uuid:string:required],8:collapse[4:uuid:string:required],9:open-node[4:uuid:string:required]";
  let application = App.create (ios_backend ()) in
  let row = { (outline_row "native-row" "Native title") with
    Model.depth = 3; has_children = true;
    tags = [{ Model.uuid = "tag"; title = "Tag" }] } in
  start application;
  send application (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] [] None None [] [] [row] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let native = descendant_with_extension renderer application root "outliner-block-row" in
  check ~msg:"iOS uses one native layout per block" (native <> -1);
  let payload = match extension_property application native "payload" with
    | Some (Lui_protocol.StringValue value) -> Yojson.Basic.from_string value
    | _ -> failwith "Native row payload missing" in
  let open Yojson.Basic.Util in
  check_eq (payload |> member "depth") (`Int 3);
  check_eq (payload |> member "title") (`String "Native title");
  let emit name = dispatch application (Lui_protocol.ExtensionEvent
    (native, "outliner-block-row", name,
      Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue "native-row"))) in
  dispatch application (Lui_protocol.ExtensionEvent
    (native, "outliner-block-row", "set-status",
      Lui_protocol.String_map.empty
      |> Lui_protocol.String_map.add "uuid" (Lui_protocol.StringValue "native-row")
      |> Lui_protocol.String_map.add "count" (Lui_protocol.IntValue (-1))));
  flush application;
  check_eq ~msg:"invalid native task selections do not mutate the graph"
    (App.model application).pending_effects [];
  emit "collapse";
  emit "edit";
  flush application;
  check_eq (App.model application).pending_effects
    [Model.ToggleOutlinerCollapsedEffect (1, "native-row"); Model.TapOutlinerBlockEffect (2, "native-row")]

let outliner_rows_render_status_tags_and_sync_failures () =
  let application = App.create (ios_backend ()) in
  let todo =
    Model.task_status "todo" "logseq.property/status.todo" "Todo" "Todo"
  in
  let tag = { Model.uuid = "tag-a"; title = "Project" } in
  let row =
    {
      (outline_row "block-a" "Ship it") with
      Model.row_status = Some todo;
      tags = [ tag ];
      sync_status = Some "failed";
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] true "" [] []
       None None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let rendered_row =
    descendant_with_identifier renderer root "outliner.block.block-a"
  in
  let payload = native_row_payload application rendered_row in
  let open Yojson.Basic.Util in
  check_eq (payload |> member "status" |> member "uuid") (`String "todo");
  check_eq (payload |> member "status" |> member "icon") (`String "app:task-todo");
  check_eq (payload |> member "tags")
    (`List [`Assoc ["uuid", `String "tag-a"; "title", `String "Project"]]);
  check_eq ~msg:"failed sync stays visible in the native row"
    (payload |> member "syncFailed") (`Bool true);
  dispatch application (Lui_protocol.ExtensionEvent
    (native_row application rendered_row, "outliner-block-row", "open-node",
      Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue "tag-a")));
  flush application;
  check_eq ~msg:"native tag presses retain typed navigation"
    (App.model application).app_navigation_path [Model.NodeRoute "tag-a"]

let outliner_long_press_selection_and_toolbar_use_typed_effects () =
  let application = App.create (ios_backend ()) in
  let row = outline_row "parent" "Parent" in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       None None [] [ "parent" ] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let chrome = native_bottom_chrome renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let rendered_row =
    descendant_with_identifier renderer outliner "outliner.block.parent"
  in
  let navigation = extension_node application "native-navigation-stack" in
  let wrapper = List.nth (children renderer navigation) 0 in
  let toolbar =
    descendant_with_identifier renderer wrapper
      "toolbar.outliner.selection"
  in
  let selection_buttons = children renderer toolbar in
  let copy_button = List.nth selection_buttons 0 in
  check ~msg:"the selected block is projected into retained row state"
    (property_bool renderer rendered_row Lui_protocol.Selected);
  check_eq ~msg:"selection exposes main's stable toolbar identifier"
    (property_string renderer toolbar Lui_protocol.AccessibilityIdentifier)
    "toolbar.outliner.selection";
  check_eq
    ~msg:
      "selection keeps its trailing action and main inset on narrow \
       screens"
    (property_string renderer toolbar Lui_protocol.StyleClass)
    "scroll-leading leading-inset-12";
  check_eq ~msg:"selection actions keep main's automation identifiers"
    (property_string renderer copy_button
       Lui_protocol.AccessibilityIdentifier)
    "button.outliner.selection.copy";
  List.iter
    (fun (index, icon, caption) ->
       let button = List.nth selection_buttons index in
       check_eq ~msg:"selection actions retain main's iconography"
         (property_string renderer button Lui_protocol.InlineIconName)
         icon;
       check_eq ~msg:"selection actions retain main's captions"
         (property_string renderer button Lui_protocol.TextValue)
         caption;
       check_eq ~msg:"selection actions retain main's fixed widths"
         (property_int renderer button Lui_protocol.WidthValue)
         (if index = 6 then 70 else 58))
    [
      (0, "app:toolbar-copy", "Copy");
      (1, "app:toolbar-outdent", "Outdent");
      (2, "app:toolbar-indent", "Indent");
      (3, "app:toolbar-delete", "Delete");
      (4, "app:toolbar-copy-reference", "Copy reference");
      (5, "app:toolbar-copy-url", "Copy URL");
      (6, "app:toolbar-unselect", "Unselect");
    ];
  check_eq ~msg:"selection replaces Capture"
    (descendant_with_identifier renderer chrome "surface.composer.root")
    (-1);
  check_eq ~msg:"selection replaces the editor toolbar"
    (descendant_with_identifier renderer chrome "toolbar.outliner.editor")
    (-1);
  dispatch application (Lui_protocol.Press copy_button);
  flush application;
  check_eq ~msg:"selection toolbar actions cross the typed core boundary"
    (App.model application).pending_effects
    [ Model.OutlinerToolbarEffect (1, "copy") ]

let kotlin_outliner_selection_toolbar_uses_compact_material_actions () =
  let application = App.create (kotlin_backend ()) in
  let row = outline_row "parent" "Parent" in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       None None [] [ "parent" ] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let selected_row =
    descendant_with_identifier renderer root "outliner.block.parent"
  in
  let surface =
    descendant_with_identifier renderer root
      "surface.outliner.selection-toolbar"
  in
  let toolbar =
    descendant_with_identifier renderer root "toolbar.outliner.selection"
  in
  let buttons = children renderer toolbar in
  check_eq ~msg:"Kotlin keeps the editor-compatible row surface"
    (node renderer selected_row)
    (Some Lui_protocol.Box);
  check ~msg:"Kotlin projects selection onto the row surface"
    (property_bool renderer selected_row Lui_protocol.Selected);
  check_eq ~msg:"Android uses compact Material action spacing"
    (property_int renderer toolbar Lui_protocol.Gap)
    4;
  check_eq ~msg:"the contextual toolbar uses Material bottom-app-bar height"
    (property_int renderer surface Lui_protocol.HeightValue)
    56;
  check_eq ~msg:"the contextual toolbar keeps balanced horizontal insets"
    (property_int renderer surface Lui_protocol.PaddingHorizontal)
    8;
  check_eq ~msg:"the contextual toolbar centers 48dp actions"
    (property_int renderer surface Lui_protocol.PaddingVertical)
    4;
  check_eq ~msg:"the contextual toolbar has a deliberate Material surface"
    (property_int renderer surface Lui_protocol.CornerRadius)
    20;
  check_eq ~msg:"selection receives a stronger contextual surface"
    (property_string renderer surface Lui_protocol.BackgroundValue)
    "surface-container-high";
  check_eq ~msg:"all selection actions remain directly reachable"
    (List.length buttons) 7;
  List.iter
    (fun button ->
       check_eq ~msg:"Android selection actions use compact 48dp targets"
         (property_int renderer button Lui_protocol.WidthValue)
         48;
       check_eq ~msg:"Android selection actions fit without vertical overflow"
         (property_int renderer button Lui_protocol.HeightValue)
         48;
       check_eq
         ~msg:"Android uses icon-only actions instead of clipped captions"
         (property_string renderer button Lui_protocol.TextValue)
         "<missing>";
       check_eq ~msg:"Android selection actions render 24dp Material glyphs"
         (property_string renderer button Lui_protocol.SizeValue)
         "icon";
       check ~msg:"icon-only actions retain an accessible label"
         (property_string renderer button Lui_protocol.AccessibilityLabel
         <> "<missing>"))
    buttons;
  check_eq ~msg:"delete stays neutral until the confirmation dialog"
    (property_string renderer (List.nth buttons 3)
       Lui_protocol.ForegroundValue)
    "muted-foreground"

let kotlin_outliner_editor_toolbar_uses_a_material_bottom_surface () =
  let application = App.create (kotlin_backend ()) in
  let row = outline_row "block-a" "Draft" in
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Draft";
      caret_utf16_offset = 5;
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       (Some editing) None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let editor_container =
    descendant_with_identifier renderer root
      "container.outliner.editor-chrome"
  in
  let surface =
    descendant_with_identifier renderer root
      "surface.outliner.editor-toolbar"
  in
  let toolbar =
    descendant_with_identifier renderer root "toolbar.outliner.editor"
  in
  let buttons = children renderer toolbar in
  check_eq ~msg:"the editor toolbar uses Material bottom-app-bar height"
    (property_int renderer surface Lui_protocol.HeightValue)
    56;
  check_eq ~msg:"editor actions have balanced horizontal insets"
    (property_int renderer surface Lui_protocol.PaddingHorizontal)
    8;
  check_eq ~msg:"editor actions are vertically centered"
    (property_int renderer surface Lui_protocol.PaddingVertical)
    4;
  check_eq ~msg:"the editor chrome has one Material surface shape"
    (property_int renderer editor_container Lui_protocol.CornerRadius)
    20;
  check_eq ~msg:"the editor and autocomplete share one Material surface"
    (property_string renderer editor_container Lui_protocol.BackgroundValue)
    "surface-container-low";
  check_eq ~msg:"all editor actions remain reachable by horizontal scroll"
    (List.length buttons) 11;
  List.iter
    (fun button ->
       check_eq ~msg:"every editor action has a 48dp target"
         (property_int renderer button Lui_protocol.WidthValue)
         48;
       check_eq ~msg:"every editor action fits the toolbar"
         (property_int renderer button Lui_protocol.HeightValue)
         48;
       check_eq ~msg:"every editor action uses a 24dp Material glyph"
         (property_string renderer button Lui_protocol.SizeValue)
         "icon")
    buttons;
  let page_reference = List.nth buttons 9 in
  check_eq ~msg:"page reference does not use an unrelated code glyph"
    (property_string renderer page_reference Lui_protocol.InlineIconName)
    "<missing>";
  check_eq ~msg:"page reference matches the iOS toolbar symbol"
    (property_string renderer page_reference Lui_protocol.TextValue)
    "[[]]"

let outliner_editor_toolbar_and_autocomplete_use_core_owned_state () =
  let application = App.create (ios_backend ()) in
  let row = outline_row "block-a" "Project [[Pro" in
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Project [[Pro";
      caret_utf16_offset = 13;
    }
  in
  let autocomplete =
    {
      Model.autocomplete_kind = Model.NodeAutocomplete;
      autocomplete_query = "Pro";
    }
  in
  let candidate =
    {
      Model.candidate_index = 10;
      candidate_label = "Project Alpha";
      candidate_value = "page-a";
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] true "" [] []
       (Some editing) (Some autocomplete) [ candidate ] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let sidebar_button =
    descendant_with_identifier renderer root "button.sidebar"
  in
  let navigation = extension_node application "native-navigation-stack" in
  let chrome = native_bottom_chrome renderer application in
  let autocomplete_bar =
    descendant_with_identifier renderer chrome
      "toolbar.outliner.autocomplete"
  in
  let editor_glass =
    descendant_extension_containing_identifier renderer application chrome
      "liquid-glass" "toolbar.outliner.autocomplete"
  in
  let autocomplete_column =
    List.nth (children renderer autocomplete_bar) 0
  in
  let candidate_button =
    descendant_with_identifier renderer autocomplete_column
      "button.outliner.autocomplete.0"
  in
  let editor_toolbar =
    descendant_with_identifier renderer chrome
      "toolbar.outliner.editor"
  in
  check_eq ~msg:"the editor is inline in the keyboard-following safe-area inset"
    (property renderer editor_toolbar Lui_protocol.PlacementValue) None;
  let editor_buttons = children renderer editor_toolbar in
  let task_button = List.nth editor_buttons 0 in
  check
    ~msg:"editing disables both the sidebar button and drawer gesture"
    (not (property_bool renderer sidebar_button Lui_protocol.Enabled));
  check_eq ~msg:"the editor reserves safe-area layout space like main"
    (extension_property application navigation
       "bottom-occupies-layout-space")
    (Some (Lui_protocol.BoolValue true));
  check_eq ~msg:"the editor and autocomplete share main's glass container"
    (extension_property application editor_glass "shape")
    (Some (Lui_protocol.StringValue "container"));
  check_eq
    ~msg:"autocomplete numbers the first visible candidate from zero"
    (property_string renderer candidate_button
       Lui_protocol.AccessibilityIdentifier)
    "button.outliner.autocomplete.0";
  check_eq ~msg:"autocomplete uses main's vertically scrolling surface"
    (node renderer autocomplete_bar)
    (Some Lui_protocol.Scroll);
  check_eq ~msg:"autocomplete keeps main's maximum height"
    (property_int renderer autocomplete_bar Lui_protocol.MaxHeight)
    220;
  check_eq ~msg:"autocomplete keeps main's outer padding"
    (property_int renderer autocomplete_column Lui_protocol.PaddingValue)
    8;
  check_eq ~msg:"autocomplete keeps main's row spacing"
    (property_int renderer autocomplete_column Lui_protocol.Gap)
    2;
  check_eq ~msg:"autocomplete rows keep main's touch target height"
    (property_int renderer candidate_button Lui_protocol.HeightValue)
    44;
  check_eq ~msg:"autocomplete rows fill the available width"
    (property_float renderer candidate_button Lui_protocol.GrowValue)
    1.0;
  check_eq ~msg:"autocomplete labels keep main's horizontal inset"
    (property_int renderer candidate_button Lui_protocol.PaddingHorizontal)
    10;
  check_eq ~msg:"autocomplete rows use the shared main-matching background"
    (property_string renderer candidate_button Lui_protocol.BackgroundValue)
    "autocomplete-row-background";
  check_eq ~msg:"autocomplete labels use readable content color"
    (property_string renderer candidate_button Lui_protocol.ForegroundValue)
    "foreground";
  check_eq ~msg:"autocomplete rows keep main's corner radius"
    (property_int renderer candidate_button Lui_protocol.CornerRadius)
    8;
  check_eq ~msg:"autocomplete labels align like main"
    (property_string renderer candidate_button Lui_protocol.TextAlignment)
    "start";
  check_eq
    ~msg:
      "the editor scrolls leading controls while pinning the trailing \
       action"
    (property_string renderer editor_toolbar Lui_protocol.StyleClass)
    "scroll-leading leading-inset-8";
  check_eq ~msg:"the editor toolbar keeps main's task identifier"
    (property_string renderer task_button Lui_protocol.AccessibilityIdentifier)
    "button.outliner.editor.task";
  check_eq
    ~msg:"the task action announces the active block status like main"
    (property_string renderer task_button Lui_protocol.AccessibilityLabel)
    "Task: None";
  List.iter
    (fun (index, icon) ->
       let button = List.nth editor_buttons index in
       check_eq ~msg:"editor actions retain main's iconography"
         (property_string renderer button Lui_protocol.InlineIconName)
         icon;
       check_eq ~msg:"editor icon buttons do not render text labels"
         (property_string renderer button Lui_protocol.TextValue)
         "<missing>";
       check_eq ~msg:"editor actions retain main's fixed widths"
         (property_int renderer button Lui_protocol.WidthValue)
         38)
    [
      (0, "app:toolbar-task");
      (1, "app:toolbar-outdent");
      (2, "app:toolbar-indent");
      (3, "app:toolbar-move-up");
      (4, "app:toolbar-move-down");
      (5, "app:toolbar-tag");
      (6, "app:toolbar-camera");
      (7, "app:toolbar-audio");
    ];
  check_eq ~msg:"the iOS editor toolbar omits the file picker"
    (descendant_with_identifier renderer editor_toolbar
       "button.outliner.editor.attachment")
    (-1);
  let page_reference_button = List.nth editor_buttons 8 in
  let hide_keyboard_button = List.nth editor_buttons 9 in
  check_eq ~msg:"page reference retains main's compact symbolic label"
    (property_string renderer page_reference_button Lui_protocol.TextValue)
    "[[]]";
  check_eq ~msg:"page reference does not replace its main-branch symbol"
    (property_string renderer page_reference_button
       Lui_protocol.InlineIconName)
    "<missing>";
  check_eq ~msg:"page reference retains main's toolbar item width"
    (property_int renderer page_reference_button Lui_protocol.WidthValue)
    38;
  check_eq ~msg:"hide keyboard stays pinned as the trailing editor action"
    (property_string renderer hide_keyboard_button
       Lui_protocol.InlineIconName)
    "app:toolbar-hide-keyboard";
  check_eq ~msg:"hide keyboard keeps the wider trailing tap target"
    (property_int renderer hide_keyboard_button Lui_protocol.WidthValue)
    42;
  check_eq ~msg:"the editor replaces Capture"
    (descendant_with_identifier renderer chrome "surface.composer.root")
    (-1);
  check_eq ~msg:"the editor excludes the selection toolbar"
    (descendant_with_identifier renderer chrome "toolbar.outliner.selection")
    (-1);
  dispatch application (Lui_protocol.Press candidate_button);
  dispatch application (Lui_protocol.Press task_button);
  flush application;
  check_eq ~msg:"autocomplete and editor actions cross the typed core boundary"
    (App.model application).pending_effects
    [
      Model.ChooseOutlinerAutocompleteEffect (1, "page-a");
      Model.OutlinerToolbarEffect (2, "task");
    ];
  check_eq ~msg:"a task mutation hides stale synced state immediately"
    (App.model application).sync_state Model.SyncingState

let kotlin_outliner_autocomplete_stacks_above_the_editor_toolbar () =
  let application = App.create (kotlin_backend ()) in
  let row = outline_row "block-a" "Draft #" in
  let editing =
    {
      Model.editing_uuid = "block-a";
      editing_title = "Draft #";
      caret_utf16_offset = 7;
    }
  in
  let autocomplete =
    {
      Model.autocomplete_kind = Model.TagAutocomplete;
      autocomplete_query = "";
    }
  in
  let candidate =
    {
      Model.candidate_index = 0;
      candidate_label = "Project";
      candidate_value = "tag-a";
    }
  in
  start application;
  send application (Model.SelectGraph "Work");
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       (Some editing) (Some autocomplete) [ candidate ] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let navigation = extension_node application "native-navigation-stack" in
  let navigation_content = List.nth (children renderer navigation) 1 in
  let editor_container =
    descendant_with_identifier renderer navigation_content
      "container.outliner.editor-chrome"
  in
  let autocomplete_bar =
    descendant_with_identifier renderer editor_container
      "toolbar.outliner.autocomplete"
  in
  let autocomplete_column =
    List.nth (children renderer autocomplete_bar) 0
  in
  let candidate_button =
    descendant_with_identifier renderer autocomplete_column
      "button.outliner.autocomplete.0"
  in
  check_eq
    ~msg:
      "Kotlin lays autocomplete above the editor toolbar instead of \
       overlaying it"
    (node renderer editor_container)
    (Some Lui_protocol.Column);
  check_eq ~msg:"tag and page autocomplete share the editor surface"
    (property_string renderer editor_container Lui_protocol.BackgroundValue)
    "surface-container-low";
  check_eq ~msg:"autocomplete and toolbar form one rounded container"
    (property_int renderer editor_container Lui_protocol.CornerRadius)
    20;
  check
    ~msg:"the autocomplete surface shares the visible vertical editor container"
    (child_with_identifier renderer editor_container
       "toolbar.outliner.autocomplete"
    <> -1);
  check_eq
    ~msg:"Kotlin fills autocomplete width with cross-axis stretching"
    (property_string renderer autocomplete_column
       Lui_protocol.CrossAlignment)
    "stretch";
  check_eq
    ~msg:"Kotlin does not flex rows along an unbounded scroll axis"
    (property_float renderer candidate_button Lui_protocol.GrowValue)
    0.0

let outliner_rows_preserve_depth_zoom_and_collapse_controls () =
  let application = App.create (ios_backend ()) in
  let row =
    {
      (outline_row "parent" "Parent") with
      Model.depth = 2;
      has_children = true;
    }
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       None None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let outliner =
    descendant_with_identifier renderer root "list.outliner"
  in
  let rendered_row =
    descendant_with_identifier renderer outliner "outliner.block.parent"
  in
  let payload = native_row_payload application rendered_row in
  let open Yojson.Basic.Util in
  check_eq ~msg:"depth is preserved for native indentation" (payload |> member "depth") (`Int 2);
  check_eq (payload |> member "hasChildren") (`Bool true);
  check_eq (payload |> member "collapsed") (`Bool false);
  check_eq ~msg:"normal pages keep an interactive zoom bullet"
    (payload |> member "journalBullet") (`Bool false);
  let native = native_row application rendered_row in
  List.iter (fun name -> dispatch application (Lui_protocol.ExtensionEvent
    (native, "outliner-block-row", name,
     Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue "parent"))))
    ["open-node"; "collapse"];
  flush application;
  check_eq
    ~msg:"both controls route through LG without triggering row editing"
    (App.model application).pending_effects
    [
      Model.OpenAppNodeEffect (1, "parent");
      Model.ToggleOutlinerCollapsedEffect (2, "parent");
    ];
  check_eq ~msg:"zoom participates in native Back navigation"
    (App.model application).app_navigation_path
    [ Model.NodeRoute "parent" ]

let journal_child_blocks_keep_zoom_navigation () =
  List.iter (fun uuid ->
  let application = App.create (ios_backend ()) in
  let root_row =
    journal_outline_row "day-root" "page-a" "Journal root" "Sep 14th, 2026"
      20260914 0
  in
  let child_row =
    journal_outline_row "block-a" "page-a" "Journal child" "Sep 14th, 2026"
      20260914 1
  in
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" [] []
       None None [] [] [ root_row; child_row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let child = descendant_with_identifier renderer root ("outliner.block." ^ uuid) in
  check_eq ~msg:"journal children keep an interactive zoom bullet"
    (Yojson.Basic.Util.member "journalBullet" (native_row_payload application child)) (`Bool false);
  dispatch application (Lui_protocol.ExtensionEvent
    (native_row application child, "outliner-block-row", "open-node",
      Lui_protocol.String_map.singleton "uuid" (Lui_protocol.StringValue uuid)));
  flush application;
  check_eq
    ~msg:
      "journal child zoom opens the block instead of acting like a \
       journal marker"
    (App.model application).pending_effects
    [ Model.OpenAppNodeEffect (1, uuid) ]) ["day-root"; "block-a"]

let outliner_row_splices_update_the_existing_keyed_projection () =
  let parent =
    { (outline_row "parent" "Parent") with Model.has_children = true }
  in
  let child =
    { (outline_row "child" "Child") with Model.depth = 1 }
  in
  let sibling = outline_row "sibling" "Sibling" in
  let collapsed_parent = { parent with Model.is_collapsed = true } in
  let initial =
    Model.update (Model.initial ())
      (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" []
         [] None None [] [] [ parent; child; sibling ] false [])
  in
  let splice =
    {
      Model.splice_start = Some 0;
      after_block_id = None;
      before_block_id = None;
      delete_count = 2;
      splice_rows = [ collapsed_parent ];
    }
  in
  let collapsed =
    Model.update initial
      (apply_core_snapshot None (empty_sidebar_projection ()) [] false "" []
         [] None None [] [] [] true [ splice ])
  in
  check_eq ~msg:"a bounded core splice preserves unaffected keyed rows"
    collapsed.outliner_rows [ collapsed_parent; sibling ]

let native_bridge_returns_initial_and_disposal_patch_batches () =
  let initial_patch = Native_bridge.initialize 2 2 0 in
  check ~msg:"initialization emits a patch" (initial_patch <> "");
  check ~msg:"the bridge exposes a root node" (Native_bridge.root_node () > 0);
  check ~msg:"disposal emits a patch" (Native_bridge.dispose () <> "")

let native_bridge_preserves_native_search_query_values () =
  ignore (Native_bridge.initialize 2 2 0);
  let application = Native_bridge.app () in
  send application (Model.SelectGraph "Work");
  send application Model.OpenSearch;
  flush application;
  let search = extension_node application "native-search-presentation" in
  ignore
    (Native_bridge.extension_event search "native-search-presentation"
       "query-changed" "project alpha" 0);
  check_eq ~msg:"the native bridge preserves the declared query field"
    (App.model application).search_query "project alpha";
  ignore (Native_bridge.dispose ())

let native_bridge_preserves_native_navigation_back_counts () =
  ignore (Native_bridge.initialize 2 2 0);
  let application = Native_bridge.app () in
  send application (Model.SelectGraph "Work");
  send application (Model.RequestAppNode "page-a");
  flush application;
  let navigation = extension_node application "native-navigation-stack" in
  ignore
    (Native_bridge.extension_event navigation "native-navigation-stack"
       "back" "" 1);
  check_eq ~msg:"the native bridge preserves the declared back count"
    (App.model application).app_navigation_path [];
  ignore (Native_bridge.dispose ())

let journal_list_remains_retained_across_sidebar_destinations () =
  let application = App.create (ios_backend ()) in
  let first_page = { Model.uuid = "page-a"; title = "First" } in
  let second_page = { Model.uuid = "page-b"; title = "Second" } in
  let sidebar =
    {
      (empty_sidebar_projection ()) with
      Model.favorites = [ first_page ];
      recent_pages = [ second_page ];
    }
  in
  let rows =
    [
      journal_outline_row "row-a" "page-a" "A" "First" 20260829 0;
      journal_outline_row "row-b" "page-b" "B" "Second" 20260828 0;
    ]
  in
  start application;
  send application
    (apply_core_snapshot (Some "Work") sidebar [] false "" [] [] None None
       [] [] rows false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let journal_pane =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "pane.journals"
  in
  let initial_list =
    descendant_with_identifier renderer journal_pane "list.outliner"
  in
  check ~msg:"journals render the retained virtual list"
    (initial_list <> -1);
  send application Model.ShowGraphs;
  flush application;
  check_eq
    ~msg:"switching destinations keeps the expensive journal tree mounted"
    (descendant_with_identifier renderer journal_pane "list.outliner")
    initial_list;
  send application (Model.SelectSidebarPage "page-a");
  flush application;
  let first_selected_pane =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "pane.selected-page"
  in
  let first_selected_list =
    descendant_with_identifier renderer first_selected_pane "list.outliner"
  in
  check_eq ~msg:"selecting a page does not rebuild the long journal list"
    (descendant_with_identifier renderer journal_pane "list.outliner")
    initial_list;
  send application Model.OpenSidebar;
  send application (Model.SelectSidebarPage "page-b");
  flush application;
  let second_selected_pane =
    descendant_with_identifier renderer (Lui_app.root_node application)
      "pane.selected-page"
  in
  let second_selected_list =
    descendant_with_identifier renderer second_selected_pane "list.outliner"
  in
  check ~msg:"switching pages creates a fresh top-aligned scroll surface"
    (first_selected_list <> second_selected_list)

let sidebar_selection_follows_visible_destination () =
  let page = { Model.uuid = "page-a"; title = "Page A" } in
  let current =
    { (Model.initial ()) with Model.selected_page = Some page }
  in
  check ~msg:"the selected page is highlighted"
    (View_base.sidebar_page_selected_ current page);
  let graphs = Model.update current Model.ShowGraphs in
  check ~msg:"graphs destination highlights the graphs row"
    (View_base.graphs_sidebar_selected_ graphs);
  check ~msg:"Graphs and a retained page cannot both be selected"
    (not (View_base.sidebar_page_selected_ graphs page))

let native_outliner_controls_match_first_line_and_main_status_shapes () =
  let application = App.create (ios_backend ()) in
  let status =
    Model.task_status "actual-status-uuid" "logseq.property/status.doing"
      "Doing" "progress"
  in
  let row =
    {
      (journal_outline_row "control-row" "page-a" "Control" "Today" 20260907
         0)
      with
      Model.row_status = Some status;
      has_children = true;
    }
  in
  check_eq
    ~msg:"status identity uses its semantic ident, never a placeholder UUID"
    (View_base.outliner_task_status_icon row)
    "app:task-doing";
  start application;
  send application
    (apply_core_snapshot None (empty_sidebar_projection ()) [] true "" [] []
       None None [] [] [ row ] false []);
  flush application;
  let renderer = Lui_app.runtime application in
  let root = main_root renderer application in
  let payload = native_row_payload application root in
  let open Yojson.Basic.Util in
  check_eq ~msg:"native task glyph uses semantic status identity"
    (payload |> member "status" |> member "icon") (`String "app:task-doing");
  check_eq ~msg:"journal roots retain interactive bullet chrome"
    (payload |> member "journalBullet") (`Bool false);
  check_eq ~msg:"native disclosure receives its child state"
    (payload |> member "hasChildren") (`Bool true)

let composer_stages_multiple_assets_until_confirmed () =
  let asset =
    {
      Model.uuid = "asset-a";
      title = "a.jpg";
      local_path = "/tmp/a.jpg";
      payload = "{}";
    }
  in
  let other = { asset with Model.uuid = "asset-b" } in
  let staged =
    Model.update
      (Model.update (Model.initial ()) (Model.StageComposerAsset asset))
      (Model.StageComposerAsset other)
  in
  let sent = Model.update staged Model.SendComposer in
  check_eq ~msg:"selection stages all assets"
    (List.length staged.composer_assets) 2;
  check_eq ~msg:"selection does not create blocks"
    (List.length staged.pending_effects) 0;
  check_eq ~msg:"confirmation creates each asset"
    (List.length sent.pending_effects) 2;
  check_eq ~msg:"repeated confirmation does not duplicate assets"
    (List.length (Model.update sent Model.SendComposer).pending_effects)
    2;
  check_eq ~msg:"removing a draft attachment does not create a block"
    (List.length
       (Model.update staged (Model.RemoveComposerAsset "asset-a"))
         .composer_assets)
    1

let composer_asset_failure_retains_draft_and_success_removes_it () =
  let asset =
    {
      Model.uuid = "asset-a";
      title = "a.jpg";
      local_path = "/tmp/a.jpg";
      payload = "{}";
    }
  in
  let staged =
    Model.update (Model.initial ()) (Model.StageComposerAsset asset)
  in
  let sent = Model.update staged Model.SendComposer in
  let active = Model.update sent (Model.DequeueEffect 1) in
  let failed = Model.update active (Model.ResolveEffect (1, false, "offline")) in
  let completed = Model.update active (Model.ResolveEffect (1, true, "{}")) in
  check_eq ~msg:"failed assets remain available for retry"
    failed.composer_assets [ asset ];
  check_eq ~msg:"successful assets leave the draft"
    completed.composer_assets []

let sidebar_settings_opens_sheet_directly () =
  let application = App.create (ios_backend ()) in
  start application;
  send application Model.OpenSidebar;
  flush application;
  let renderer = Lui_app.runtime application in
  let root = Lui_app.root_node application in
  let settings = descendant_with_identifier renderer root "button.sidebar.settings" in
  check ~msg:"settings is available directly beside the graph switch" (settings <> -1);
  dispatch application (Lui_protocol.Press settings);
  flush application;
  check ~msg:"a single settings click opens the sheet" (App.model application).settings_open;
  check ~msg:"settings dismisses the sidebar" (not (App.model application).sidebar_open)

let search_reveal_mounts_only_the_target_window () =
  List.iter (fun count ->
    let application = App.create (ios_backend ()) in
    let rows = List.init count (fun index -> outline_row ("b" ^ string_of_int index) "Block") in
    let target = "b" ^ string_of_int (count - 20) in
    let route = { (node_projection "page" "page" "Page" [] []) with
      Model.node_scroll_target = Some target; node_outliner_rows = rows } in
    start application;
    send application Model.OpenSearch;
    send application (Model.RequestSearchResult target);
    flush application;
    check ~msg:"search requests page reveal while bullet presses keep zoom semantics"
      (List.exists (function Model.OpenSearchResultEffect (_, uuid) -> uuid = target | _ -> false)
        (App.model application).pending_effects);
    send application (Model.ApplyCoreSnapshot { (empty_core_projection ()) with
      Model.selected_graph_id = Some "graph"; node_routes = [route]; outliner_rows = rows });
    flush application;
    let renderer = Lui_app.runtime application in
    let navigation = extension_node application "native-search-presentation" in
    let window = descendant_with_identifier renderer navigation "outliner.window" in
    let metadata = Lui_protocol.data_attrs_decode (property_string renderer window Lui_protocol.DataAttrs) in
    let first = int_of_string (List.assoc "data-virtual-start" metadata) in
    check ~msg:"search mounts the distant result without walking through every preceding row"
      (first <= count - 20 && count - 20 < first + 32);
    check ~msg:"the requested result is materialized"
      (descendant_with_identifier renderer window ("outliner.block." ^ target) <> -1);
    check ~msg:"phone search never mounts more than 32 blocks"
      (List.length (children renderer window) <= 32);
    check_eq ~msg:"the navigation history records the containing page"
      (App.model application).search_navigation_path [Model.NodeRoute "page"];
    send application (Model.RequestSearchNode target);
    flush application;
    check_eq ~msg:"the revealed block can still be zoomed through its bullet"
      (App.model application).search_navigation_path [Model.NodeRoute "page"; Model.NodeRoute target]
  ) [1000; 10000]

let selected_page_survives_node_navigation () =
  let application = App.create (ios_backend ()) in
  let rows = [outline_row "parent" "Parent"; outline_row "child" "Child"] in
  let sidebar = { (empty_sidebar_projection ()) with
    Model.selected_page = Some { uuid = "page"; title = "Page" } } in
  let projection = { (empty_core_projection ()) with
    Model.selected_graph_id = Some "graph"; sidebar;
    journal_outliner_rows = rows; outliner_rows = rows } in
  start application;
  send application (Model.ApplyCoreSnapshot projection);
  flush application;
  let renderer = Lui_app.runtime application in
  let pane () = descendant_with_identifier renderer (main_root renderer application) "pane.selected-page" in
  let original = pane () in
  check ~msg:"the selected page is mounted" (original <> -1);
  send application (Model.RequestAppNode "child");
  let route = { (node_projection "child" "page" "Child" [] []) with
    Model.node_outliner_rows = [List.nth rows 1] } in
  send application (Model.ApplyCoreSnapshot { projection with
    node_routes = [route]; outliner_rows = route.node_outliner_rows });
  flush application;
  check_eq ~msg:"pushing a node retains the source page and its native scroll view" (pane ()) original;
  check ~msg:"the source page still contains its original block during interactive back"
    (descendant_with_identifier renderer original "outliner.block.parent" <> -1);
  send application (Model.BackAppNavigation 1);
  send application (Model.ApplyCoreSnapshot projection);
  flush application;
  check_eq ~msg:"back reuses the original page instead of resetting its scroll view" (pane ()) original

let block_node_breadcrumbs_preserve_navigation_context () =
  List.iter
    (fun search_ ->
       let application = App.create (ios_backend ()) in
       let row =
         {
           (journal_outline_row "child" "journal" "Hello" "Journal" 20260913
              0)
           with
           row_breadcrumbs =
             [
               { Model.uuid = "journal"; title = "Journal" };
               { Model.uuid = "parent"; title = "Parent" };
             ];
         }
       in
       let route =
         {
           (node_projection "child" "journal" "Hello" [] []) with
           Model.node_outliner_rows = [ row ];
         }
       in
       start application;
       if search_ then send application Model.OpenSearch;
       send application
         (if search_ then Model.RequestSearchNode "child"
          else Model.RequestAppNode "child");
       send application
         (apply_core_snapshot None (empty_sidebar_projection ()) [] false ""
            [] [ route ] None None [] [] [ row ] false []);
       flush application;
       let renderer = Lui_app.runtime application in
       let navigation =
         extension_node application
           (if search_ then "native-search-presentation"
            else "native-navigation-stack")
       in
       let trail =
         descendant_with_identifier renderer navigation "breadcrumb.node"
       in
       let journal =
         descendant_with_identifier renderer trail "button.breadcrumb.journal"
       in
       let parent =
         descendant_with_identifier renderer trail "button.breadcrumb.parent"
       in
       check_eq
           ~msg:"block details do not repeat their content as a heading"
           (descendant_with_identifier renderer navigation "title.node")
           (-1);
       check_eq ~msg:"block navigation displays the containing page"
         (property_string renderer journal Lui_protocol.TextValue)
         "Journal";
       check_eq ~msg:"block navigation displays its parent"
         (property_string renderer parent Lui_protocol.TextValue)
         "Parent";
       dispatch application (Lui_protocol.Press parent);
       flush application;
       check_eq ~msg:"ancestor links stay in the current navigation stack"
         (if search_ then (App.model application).search_navigation_path
          else (App.model application).app_navigation_path)
         [ Model.NodeRoute "child"; Model.NodeRoute "parent" ])
    [ false; true ]

let composer_attachment_previews_remove_only_the_selected_draft () =
  let application = App.create (ios_backend ()) in
  let asset =
    {
      Model.uuid = "asset-a";
      title = "a.jpg";
      local_path = "/tmp/a.jpg";
      payload = "{}";
    }
  in
  start application;
  send application (Model.SelectGraph "Work");
  send application (Model.StageComposerAsset asset);
  send application
    (Model.StageComposerAsset { asset with Model.uuid = "asset-b" });
  flush application;
  let renderer = Lui_app.runtime application in
  let root = native_bottom_chrome renderer application in
  let preview =
    descendant_with_identifier renderer root "composer.asset.asset-a"
  in
  let remove =
    descendant_with_identifier renderer preview "composer.asset.remove"
  in
  let attachment =
    descendant_with_identifier renderer root "button.attachment"
  in
  check_eq ~msg:"attachment preview is a square tile"
    (property_int renderer preview Lui_protocol.WidthValue)
    128;
  check_eq ~msg:"preview has room to recognize the attachment"
    (property_int renderer preview Lui_protocol.HeightValue)
    128;
  check_eq ~msg:"the add symbol uses the same 18-point size as the send arrow"
    (property renderer attachment Lui_protocol.SizeValue)
    None;
  check_eq ~msg:"the add symbol keeps a regular stroke weight"
    (property renderer attachment Lui_protocol.StyleClass)
    None;
  dispatch application (Lui_protocol.Press remove);
  flush application;
  check_eq ~msg:"the close button removes only its own draft"
    (List.length (App.model application).composer_assets) 1;
  check_eq ~msg:"other attachments remain staged"
    (List.nth (App.model application).composer_assets 0).Model.uuid
    "asset-b";
  check_eq ~msg:"removing an attachment never submits it"
    (List.length (App.model application).pending_effects) 0

let ui_session_restores_after_process_relaunch () =
  let original =
    {
      (Model.initial ()) with
      Model.selected_graph_id = Some "graph-a";
      composer_expanded = true;
      search_open = true;
      search_query = "hello";
      app_navigation_path = [ Model.NodeRoute "page-a" ];
      search_navigation_path = [ Model.NodeRoute "block-b" ];
      settings_open = true;
    }
  in
  let saved = Model.ui_session original in
  let fresh =
    { (Model.initial ()) with Model.selected_graph_id = Some "graph-a" }
  in
  let restored = Model.update fresh (Model.RestoreUISession saved) in
  check_eq ~msg:"reopen Capture" restored.composer_expanded true;
  check_eq ~msg:"reopen Search" restored.search_open true;
  check_eq ~msg:"restore query" restored.search_query "hello";
  check_eq ~msg:"restore app path" restored.app_navigation_path
    original.app_navigation_path;
  check_eq ~msg:"restore search path" restored.search_navigation_path
    original.search_navigation_path;
  check_eq ~msg:"restore settings" restored.settings_open true;
  check_eq ~msg:"reload both routes and search results"
    (List.length restored.pending_effects) 3;
  check_eq ~msg:"never restore another graph's state"
    (Model.update (Model.initial ()) (Model.RestoreUISession saved))
    (Model.initial ())

let ui_session_preserves_independently_restored_composer_draft () =
  let previous =
    {
      (Model.initial ()) with
      Model.selected_graph_id = Some "graph-a";
      composer_draft = "Older draft";
    }
  in
  let session = Model.ui_session previous in
  List.iter
    (fun draft ->
      let fresh =
        { (Model.initial ()) with Model.selected_graph_id = Some "graph-a" }
      in
      let hydrated = Model.update fresh (Model.ApplyComposerDraft draft) in
      let restored = Model.update hydrated (Model.RestoreUISession session) in
      check_eq ~msg:"navigation restoration cannot replace authoritative text"
        restored.composer_draft draft)
    [ "Older draft / latest edit"; "" ]

let library_does_not_offer_an_empty_outline_editor () =
  let base = { (Model.initial ()) with Model.selected_graph = Some "Work";
    selected_page_ready = true } in
  let page title = { base with Model.selected_page = Some { uuid = "page"; title } } in
  check ~msg:"normal empty pages still allow a first block"
    (View_base.node_can_add_first_block_ (page "Notes"));
  check ~msg:"Library has no empty outliner prompt"
    (not (View_base.node_can_add_first_block_ (page "Library")))

let graph_picker_prioritizes_downloaded_and_recent_graphs () =
  let graph id = { Model.id; name = id; is_encrypted = false; is_ready = true } in
  let initial = { (Model.initial ()) with Model.graphs = List.map graph ["remote"; "old"; "recent"];
    local_graph_ids = ["old"; "recent"] } in
  let open_graph current graph_id =
    let pending = Model.update current (Model.RequestOpenGraph graph_id) in
    let id = pending.next_effect_id - 1 in
    let in_flight = Model.update pending (Model.DequeueEffect id) in
    Model.update in_flight (Model.ResolveEffect (id, true, "")) in
  let opened = open_graph (open_graph initial "old") "recent" in
  let ids current = List.map (fun (g : Model.graph) -> g.id) (View_base.model_graphs current) in
  check_eq ~msg:"downloaded graphs precede remote ones and use most-recent order"
    (ids opened) ["recent"; "old"; "remote"];
  let restored = Model.update { initial with selected_graph_id = opened.selected_graph_id }
    (Model.RestoreUISession (Model.ui_session opened)) in
  check_eq ~msg:"recent graph ordering survives app relaunch"
    (ids restored) ["recent"; "old"; "remote"]

let quick_actions_open_from_existing_navigation () =
  let current =
    {
      (Model.initial ()) with
      Model.search_open = true;
      settings_open = true;
      destination = Model.FlashcardsDestination;
      composer_draft = "Keep my draft";
      app_navigation_path = [ Model.NodeRoute "old-page" ];
      search_navigation_path = [ Model.NodeRoute "old-search" ];
    }
  in
  let capture = Model.update current (Model.OpenQuickAction "capture") in
  let audio = Model.update current (Model.OpenQuickAction "audio") in
  let journal = Model.update current (Model.OpenQuickAction "journal") in
  check_eq ~msg:"quick capture targets the journal" capture.destination
    Model.JournalsDestination;
  check_eq ~msg:"quick action closes search overlay" capture.search_open
    false;
  check_eq ~msg:"quick action closes settings overlay"
    capture.settings_open false;
  check_eq ~msg:"quick action clears previous page navigation"
    capture.app_navigation_path [];
  check_eq ~msg:"quick action clears previous search navigation"
    capture.search_navigation_path [];
  check_eq ~msg:"quick capture opens composer" capture.composer_expanded
    true;
  check_eq ~msg:"quick action preserves unsent text" capture.composer_draft
    "Keep my draft";
  check_eq ~msg:"audio returns into composer" audio.composer_expanded true;
  check_eq ~msg:"audio clears page then opens recorder"
    (List.length audio.pending_effects) 2;
  check_eq ~msg:"journal action shows journal" journal.composer_expanded
    false;
  check_eq ~msg:"unknown actions do nothing"
    (Model.update current (Model.OpenQuickAction "unknown"))
    current
let cases =
  [
    case "sync-checkpoint-encoding-is-lg-owned" sync_checkpoint_encoding_is_lg_owned;
    case "flashcard-state-codec-is-lg-owned" flashcard_state_codec_is_lg_owned;
    case "edn-codec-is-lg-owned" edn_codec_is_lg_owned;
    case "datascript-value-ref-conversion-is-lg-owned" datascript_value_ref_conversion_is_lg_owned;
    case "ref-text-converts-between-editor-and-storage-forms" ref_text_converts_between_editor_and_storage_forms;
    case "fractional-order-generates-logseq-compatible-keys" fractional_order_generates_logseq_compatible_keys;
    case "empty-outliner-rows-use-the-main-untitled-accessibility-title" empty_outliner_rows_use_the_main_untitled_accessibility_title;
    case "synced-header-control-uses-the-main-accessibility-label" synced_header_control_uses_the_main_accessibility_label;
    case "sync-indicator-prioritizes-connectivity-before-pending-work" sync_indicator_prioritizes_connectivity_before_pending_work;
    case "settings-navigation-tabs-and-diagnostics-are-lg-owned" settings_navigation_tabs_and_diagnostics_are_lg_owned;
    case "settings-preferences-persist-without-dismissing-the-sheet" settings_preferences_persist_without_dismissing_the_sheet;
    case "settings-reject-invalid-connections-and-preserve-required-tabs" settings_reject_invalid_connections_and_preserve_required_tabs;
    case "settings-snapshot-normalizes-sidebar-tabs-at-the-lg-boundary" settings_snapshot_normalizes_sidebar_tabs_at_the_lg_boundary;
    case "runtime-log-filters-refresh-and-successful-results-enter-lg-state" runtime_log_filters_refresh_and_successful_results_enter_lg_state;
    case "graph-effect-success-owns-selection-and-selected-deletion-cleanup" graph_effect_success_owns_selection_and_selected_deletion_cleanup;
    case "graph-refresh-failure-enters-the-picker-error-state" graph_refresh_failure_enters_the_picker_error_state;
    case "encrypted-graph-unlock-is-owned-by-lg" encrypted_graph_unlock_is_owned_by_lg;
    case "encrypted-graph-snapshot-prompts-once-per-selection" encrypted_graph_snapshot_prompts_once_per_selection;
    case "encrypted-graph-unlock-renders-the-secure-field-contract" encrypted_graph_unlock_renders_the_secure_field_contract;
    case "encrypted-graph-unlock-has-a-stable-native-effect-payload" encrypted_graph_unlock_has_a_stable_native_effect_payload;
    case "graph-database-export-has-a-stable-native-effect-payload" graph_database_export_has_a_stable_native_effect_payload;
    case "cancel-outliner-editing-has-a-stable-native-effect-payload" cancel_outliner_editing_has_a_stable_native_effect_payload;
    case "settings-render-the-main-branch-navigation-contract" settings_render_the_main_branch_navigation_contract;
    case "kotlin-settings-sheet-uses-one-bounded-scroll-layout" kotlin_settings_sheet_uses_one_bounded_scroll_layout;
    case "kotlin-settings-tabs-open-through-the-rendered-press-handler" kotlin_settings_tabs_open_through_the_rendered_press_handler;
    case "kotlin-runtime-log-actions-fit-phone-width" kotlin_runtime_log_actions_fit_phone_width;
    case "kotlin-settings-use-full-width-material-controls" kotlin_settings_use_full_width_material_controls;
    case "settings-tabs-match-main-visibility-and-movement-boundaries" settings_tabs_match_main_visibility_and_movement_boundaries;
    case "android-disclosure-and-selection-icons-use-material-semantics" android_disclosure_and_selection_icons_use_material_semantics;
    case "settings-tabs-render-saved-order-and-separate-available-tabs" settings_tabs_render_saved_order_and_separate_available_tabs;
    case "settings-language-picker-exposes-and-validates-all-main-choices" settings_language_picker_exposes_and_validates_all_main_choices;
    case "settings-community-links-use-a-typed-platform-boundary" settings_community_links_use_a_typed_platform_boundary;
    case "authentication-entry-is-lg-owned-and-idempotent" authentication_entry_is_lg_owned_and_idempotent;
    case "authentication-screen-renders-from-lg-state" authentication_screen_renders_from_lg_state;
    case "authentication-screen-uses-the-product-name-on-every-host" authentication_screen_uses_the_product_name_on_every_host;
    case "outliner-editor-extension-contract-is-pinned" outliner_editor_extension_contract_is_pinned;
    case "outliner-block-content-extension-contract-is-pinned" outliner_block_content_extension_contract_is_pinned;
    case "native-navigation-stack-extension-contract-is-pinned" native_navigation_stack_extension_contract_is_pinned;
    case "native-search-presentation-extension-contract-is-pinned" native_search_presentation_extension_contract_is_pinned;
    case "liquid-glass-remains-an-ios-local-tweak" liquid_glass_remains_an_ios_local_tweak;
    case "outliner-drag-selects-once-and-drop-keeps-placement" outliner_drag_selects_once_and_drop_keeps_placement;
    case "initial-shell-renders-the-graph-picker-without-a-selected-graph" initial_shell_renders_the_graph_picker_without_a_selected_graph;
    case "graph-picker-not-ready-status-matches-main-copy" graph_picker_not_ready_status_matches_main_copy;
    case "graph-picker-matches-main-layout-actions-errors-and-overflow-menu" graph_picker_matches_main_layout_actions_errors_and_overflow_menu;
    case "kotlin-graph-picker-uses-a-material-empty-state" kotlin_graph_picker_uses_a_material_empty_state;
    case "persisted-graph-loading-hides-the-launch-picker" persisted_graph_loading_hides_the_launch_picker;
    case "kotlin-loading-and-errors-use-material-feedback-surfaces" kotlin_loading_and_errors_use_material_feedback_surfaces;
    case "graph-and-sync-actions-update-retained-status-in-place" graph_and_sync_actions_update_retained_status_in_place;
    case "sync-details-render-projected-cursor-and-trigger-the-existing-pump" sync_details_render_projected_cursor_and_trigger_the_existing_pump;
    case "sync-details-show-the-last-sync-failure" sync_details_show_the_last_sync_failure;
    case "pending-sync-patches-preserve-the-current-screen-and-cursor" pending_sync_patches_preserve_the_current_screen_and_cursor;
    case "graph-catalog-patches-preserve-the-active-editor-state" graph_catalog_patches_preserve_the_active_editor_state;
    case "sidebar-state-and-page-selection-are-owned-by-lg" sidebar_state_and_page_selection_are_owned_by_lg;
    case "sidebar-renders-main-branch-navigation-identifiers" sidebar_renders_main_branch_navigation_identifiers;
    case "sidebar-drag-reserves-app-navigation" sidebar_drag_reserves_app_navigation;
    case "selected-sidebar-pages-render-their-outliner-and-related-content" selected_sidebar_pages_render_their_outliner_and_related_content;
    case "flashcard-presentation-and-review-state-are-owned-by-lg" flashcard_presentation_and_review_state_are_owned_by_lg;
    case "load-older-journals-coalesces-while-pending" load_older_journals_coalesces_while_pending;
    case "unrelated-snapshots-preserve-the-journal-pagination-window" unrelated_snapshots_preserve_the_journal_pagination_window;
    case "journal-node-insertion-keeps-the-rendered-sibling-position" journal_node_insertion_keeps_the_rendered_sibling_position;
    case "capture-refreshes-the-retained-journal-behind-a-node-route" capture_refreshes_the_retained_journal_behind_a_node_route;
    case "recent-journal-edits-refresh-the-retained-journals-pane" recent_journal_edits_refresh_the_retained_journals_pane;
    case "synchronized-capture-refreshes-an-already-visible-journal" synchronized_capture_refreshes_an_already_visible_journal;
    case "journal-refresh-applies-edits-deletions-and-a-new-day-without-loading-older-days" journal_refresh_applies_edits_deletions_and_a_new_day_without_loading_older_days;
    case "flashcard-reveal-state-resets-only-when-the-current-card-changes" flashcard_reveal_state_resets_only_when_the_current_card_changes;
    case "flashcards-render-the-main-branch-reveal-and-rating-contract" flashcards_render_the_main_branch_reveal_and_rating_contract;
    case "flashcards-render-empty-and-non-cloze-control-states" flashcards_render_empty_and_non_cloze_control_states;
    case "sidebar-flashcards-link-selects-the-flashcard-destination" sidebar_flashcards_link_selects_the_flashcard_destination;
    case "graph-catalog-and-lifecycle-state-are-owned-by-lg" graph_catalog_and_lifecycle_state_are_owned_by_lg;
    case "graph-picker-surfaces-open-graph-effect-failures" graph_picker_surfaces_open_graph_effect_failures;
    case "graphs-render-the-existing-catalog-and-modal-contract" graphs_render_the_existing_catalog_and_modal_contract;
    case "kotlin-graphs-use-a-compact-material-action-group" kotlin_graphs_use_a_compact_material_action_group;
    case "kotlin-add-graph-sheet-uses-one-material-form-layout" kotlin_add_graph_sheet_uses_one_material_form_layout;
    case "kotlin-add-graph-sheet-shows-creation-errors-inline" kotlin_add_graph_sheet_shows_creation_errors_inline;
    case "graph-lifecycle-effects-disable-duplicate-actions" graph_lifecycle_effects_disable_duplicate_actions;
    case "empty-graph-picker-replaces-refresh-with-progress-while-loading" empty_graph_picker_replaces_refresh_with_progress_while_loading;
    case "graph-deletion-confirmation-names-the-local-graph" graph_deletion_confirmation_names_the_local_graph;
    case "kotlin-graph-deletion-uses-a-material-destructive-dialog" kotlin_graph_deletion_uses_a_material_destructive_dialog;
    case "search-lifecycle-keeps-query-owned-by-the-lg-model" search_lifecycle_keeps_query_owned_by_the_lg_model;
    case "bottom-chrome-presentation-is-mutually-exclusive" bottom_chrome_presentation_is_mutually_exclusive;
    case "composer-matches-the-main-branch-expand-draft-and-send-contract" composer_matches_the_main_branch_expand_draft_and_send_contract;
    case "ios-capture-and-search-match-main-native-metrics" ios_capture_and_search_match_main_native_metrics;
    case "composer-dismissal-preserves-an-unsent-draft" composer_dismissal_preserves_an_unsent_draft;
    case "pending-outliner-text-keeps-the-latest-optimistic-edit" pending_outliner_text_keeps_the_latest_optimistic_edit;
    case "outliner-typing-removes-stale-autocomplete-candidates" outliner_typing_removes_stale_autocomplete_candidates;
    case "autocomplete-selection-waits-for-pending-text-to-settle" autocomplete_selection_waits_for_pending_text_to_settle;
    case "hide-keyboard-optimistically-finishes-outliner-editing" hide_keyboard_optimistically_finishes_outliner_editing;
    case "outliner-return-handoff-retains-one-native-editor-node" outliner_return_handoff_retains_one_native_editor_node;
    case "composer-draft-restore-focus-and-dismissal-are-owned-by-lg" composer_draft_restore_focus_and_dismissal_are_owned_by_lg;
    case "composer-refocus-always-emits-an-autofocus-edge" composer_refocus_always_emits_an_autofocus_edge;
    case "composer-renders-autofocus-and-native-outside-dismissal" composer_renders_autofocus_and_native_outside_dismissal;
    case "kotlin-composer-matches-ios-chrome" kotlin_composer_matches_ios_chrome;
    case "kotlin-sidebar-uses-compact-material-drawer-metrics" kotlin_sidebar_uses_compact_material_drawer_metrics;
    case "composer-attachment-selection-is-owned-by-lg" composer_attachment_selection_is_owned_by_lg;
    case "composer-attachment-menu-preserves-main-actions" composer_attachment_menu_preserves_main_actions;
    case "composer-attachment-picker-owns-each-presented-action" composer_attachment_picker_owns_each_presented_action;
    case "composer-task-status-selection-and-send-are-owned-by-lg" composer_task_status_selection_and_send_are_owned_by_lg;
    case "composer-task-status-menu-preserves-main-actions" composer_task_status_menu_preserves_main_actions;
    case "task-capture-has-a-stable-native-effect-payload" task_capture_has_a_stable_native_effect_payload;
    case "task-status-choices-preserve-main-built-in-fallbacks" task_status_choices_preserve_main_built_in_fallbacks;
    case "native-bridge-renders-restored-authentication-in-the-first-patch" native_bridge_renders_restored_authentication_in_the_first_patch;
    case "native-bridge-selects-the-kotlin-host-profile" native_bridge_selects_the_kotlin_host_profile;
    case "kotlin-search-presentation-owns-an-opaque-background" kotlin_search_presentation_owns_an_opaque_background;
    case "kotlin-node-route-owns-an-opaque-background" kotlin_node_route_owns_an_opaque_background;
    case "native-bridge-drains-and-resolves-typed-effects-once" native_bridge_drains_and_resolves_typed_effects_once;
    case "successful-effect-resolution-preserves-the-core-response-for-projection" successful_effect_resolution_preserves_the_core_response_for_projection;
    case "app-navigation-matches-the-main-branch-path-contract" app_navigation_matches_the_main_branch_path_contract;
    case "native-header-title-follows-the-active-destination" native_header_title_follows_the_active_destination;
    case "native-header-title-follows-the-optimistic-navigation-path" native_header_title_follows_the_optimistic_navigation_path;
    case "native-back-count-is-reduced-as-one-navigation-transition" native_back_count_is_reduced_as_one_navigation_transition;
    case "navigation-requests-and-back-cross-the-core-effect-boundary" navigation_requests_and_back_cross_the_core_effect_boundary;
    case "native-search-back-and-dismiss-own-the-full-screen-search-path" native_search_back_and_dismiss_own_the_full_screen_search_path;
    case "native-search-query-event-updates-the-lg-search-model" native_search_query_event_updates_the_lg_search_model;
    case "destination-navigation-ends-active-outliner-editing" destination_navigation_ends_active_outliner_editing;
    case "failed-navigation-effects-restore-the-optimistic-path" failed_navigation_effects_restore_the_optimistic_path;
    case "active-node-route-renders-a-core-backed-navigation-screen" active_node_route_renders_a_core_backed_navigation_screen;
    case "ios-node-navigation-is-owned-by-the-native-stack" ios_node_navigation_is_owned_by_the_native_stack;
    case "kotlin-navigation-and-search-own-composed-standard-children" kotlin_navigation_and_search_own_composed_standard_children;
    case "kotlin-navigation-renders-each-active-node-row-once" kotlin_navigation_renders_each_active_node_row_once;
    case "kotlin-selected-pages-unmount-the-hidden-journal-pane" kotlin_selected_pages_unmount_the_hidden_journal_pane;
    case "kotlin-selected-page-navigation-renders-the-opened-node" kotlin_selected_page_navigation_renders_the_opened_node;
    case "native-navigation-retains-the-journal-and-every-node-route" native_navigation_retains_the_journal_and_every_node_route;
    case "native-navigation-retains-repeated-node-visits" native_navigation_retains_repeated_node_visits;
    case "journal-navigation-exposes-an-immediate-preview-route" journal_navigation_exposes_an_immediate_preview_route;
    case "block-navigation-exposes-an-immediate-outliner-preview-route" block_navigation_exposes_an_immediate_outliner_preview_route;
    case "popped-native-path-restores-root-before-core-route-cleanup" popped_native_path_restores_root_before_core_route_cleanup;
    case "app-and-search-routes-are-retained-by-distinct-native-stacks" app_and_search_routes_are_retained_by_distinct_native_stacks;
    case "closed-search-does-not-render-core-node-routes" closed_search_does_not_render_core_node_routes;
    case "empty-node-routes-add-the-first-block-through-the-core" empty_node_routes_add_the_first_block_through_the_core;
    case "older-journals-use-an-invisible-scroll-sentinel" older_journals_use_an_invisible_scroll_sentinel;
    case "older-journals-only-appear-at-the-journal-root" older_journals_only_appear_at_the_journal_root;
    case "journal-section-markers-preserve-boundaries-and-stable-pages" journal_section_markers_preserve_boundaries_and_stable_pages;
    case "journal-section-markers-recompute-after-row-splices" journal_section_markers_recompute_after_row_splices;
    case "journal-home-keeps-first-day-viewport-and-later-block-items-flat" journal_home_keeps_first_day_viewport_and_later_block_items_flat;
    case "journal-rows-stay-flat-while-retaining-the-first-viewport" journal_rows_stay_flat_while_retaining_the_first_viewport;
    case "selected-pages-do-not-render-journal-home-headings" selected_pages_do_not_render_journal_home_headings;
    case "search-navigation-is-isolated-and-cleared-with-the-presentation" search_navigation_is_isolated_and_cleared_with_the_presentation;
    case "search-query-publishes-a-core-effect-and-rejects-stale-results" search_query_publishes_a_core_effect_and_rejects_stale_results;
    case "search-results-render-as-keyed-native-rows" search_results_render_as_keyed_native_rows;
    case "search-renders-main-empty-states-and-result-sections" search_renders_main_empty_states_and_result_sections;
    case "native-search-clear-updates-lg-owned-query" native_search_clear_updates_lg_owned_query;
    case "core-snapshot-renders-keyed-outliner-rows" core_snapshot_renders_keyed_outliner_rows;
    case "reselecting-the-current-page-preserves-loaded-rows" reselecting_the_current_page_preserves_loaded_rows;
    case "large-node-pages-virtualize-each-nested-block" large_node_pages_virtualize_each_nested_block;
    case "ten-thousand-blocks-mount-only-the-requested-window" ten_thousand_blocks_mount_only_the_requested_window;
    case "distant-outline-contents-load-without-replacing-the-page" distant_outline_contents_are_loaded_without_replacing_the_page;
    case "returning-to-a-scrolled-page-keeps-hydrated-rows-mounted" returning_to_a_scrolled_page_keeps_hydrated_rows_mounted;
    case "search-only-patches-preserve-the-open-outline" search_only_patches_preserve_the_open_outline;
    case "large-tag-and-reference-sections-virtualize-each-block" large_tag_and_reference_sections_virtualize_each_block;
    case "selected-page-waits-for-blocks-before-showing-empty-state" selected_page_waits_for_blocks_before_showing_empty_state;
    case "outliner-rows-live-inside-a-native-virtual-list" outliner_rows_live_inside_a_native_virtual_list;
    case "projected-markup-renders-through-the-native-rich-block-extension" projected_markup_renders_through_the_native_rich_block_extension;
    case "projected-assets-render-and-open-through-the-native-extension" projected_assets_render_and_open_through_the_native_extension;
    case "outliner-row-press-publishes-a-typed-core-effect" outliner_row_press_publishes_a_typed_core_effect;
    case "kotlin-rich-rows-own-their-primary-tap" kotlin_rich_rows_own_their_primary_tap;
    case "active-page-actions-use-typed-core-and-platform-effects" active_page_actions_use_typed_core_and_platform_effects;
    case "page-delete-dialog-exposes-stable-material-actions" page_delete_dialog_exposes_stable_material_actions;
    case "connection-menu-matches-active-page-actions" connection_menu_matches_active_page_actions;
    case "outliner-structure-controls-use-native-navigation-and-core-effects" outliner_structure_controls_use_native_navigation_and_core_effects;
    case "outliner-task-status-selection-uses-the-core-event-boundary" outliner_task_status_selection_uses_the_core_event_boundary;
    case "kotlin-outliner-markers-match-ios-visual-metrics" kotlin_outliner_markers_match_ios_visual_metrics;
    case "ios rows use one native layout and keep typed actions" ios_rows_use_one_native_layout_and_keep_typed_actions;
    case "outliner-rows-render-status-tags-and-sync-failures" outliner_rows_render_status_tags_and_sync_failures;
    case "outliner-long-press-selection-and-toolbar-use-typed-effects" outliner_long_press_selection_and_toolbar_use_typed_effects;
    case "kotlin-outliner-selection-toolbar-uses-compact-material-actions" kotlin_outliner_selection_toolbar_uses_compact_material_actions;
    case "kotlin-outliner-editor-toolbar-uses-a-material-bottom-surface" kotlin_outliner_editor_toolbar_uses_a_material_bottom_surface;
    case "outliner-editor-toolbar-and-autocomplete-use-core-owned-state" outliner_editor_toolbar_and_autocomplete_use_core_owned_state;
    case "kotlin-outliner-autocomplete-stacks-above-the-editor-toolbar" kotlin_outliner_autocomplete_stacks_above_the_editor_toolbar;
    case "outliner-rows-preserve-depth-zoom-and-collapse-controls" outliner_rows_preserve_depth_zoom_and_collapse_controls;
    case "journal-child-blocks-keep-zoom-navigation" journal_child_blocks_keep_zoom_navigation;
    case "outliner-row-splices-update-the-existing-keyed-projection" outliner_row_splices_update_the_existing_keyed_projection;
    case "native-bridge-returns-initial-and-disposal-patch-batches" native_bridge_returns_initial_and_disposal_patch_batches;
    case "native-bridge-preserves-native-search-query-values" native_bridge_preserves_native_search_query_values;
    case "native-bridge-preserves-native-navigation-back-counts" native_bridge_preserves_native_navigation_back_counts;
    case "journal-list-remains-retained-across-sidebar-destinations" journal_list_remains_retained_across_sidebar_destinations;
    case "sidebar-selection-follows-visible-destination" sidebar_selection_follows_visible_destination;
    case "native-outliner-controls-match-first-line-and-main-status-shapes" native_outliner_controls_match_first_line_and_main_status_shapes;
    case "composer-stages-multiple-assets-until-confirmed" composer_stages_multiple_assets_until_confirmed;
    case "composer-asset-failure-retains-draft-and-success-removes-it" composer_asset_failure_retains_draft_and_success_removes_it;
    case "sidebar-settings-opens-sheet-directly" sidebar_settings_opens_sheet_directly;
    case "search-reveal-mounts-only-the-target-window" search_reveal_mounts_only_the_target_window;
    case "selected-page-survives-node-navigation" selected_page_survives_node_navigation;
    case "block-node-breadcrumbs-preserve-navigation-context" block_node_breadcrumbs_preserve_navigation_context;
    case "composer-attachment-previews-remove-only-the-selected-draft" composer_attachment_previews_remove_only_the_selected_draft;
    case "library-does-not-offer-empty-outline" library_does_not_offer_an_empty_outline_editor;
    case "graph-picker-prioritizes-downloaded-and-recent" graph_picker_prioritizes_downloaded_and_recent_graphs;
    case "ui-session-restores-after-process-relaunch" ui_session_restores_after_process_relaunch;
    case "ui-session-preserves-independently-restored-composer-draft"
      ui_session_preserves_independently_restored_composer_draft;
    case "quick-actions-open-from-existing-navigation" quick_actions_open_from_existing_navigation;
  ]
