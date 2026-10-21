open Lui_protocol

let string_wire_value value = StringValue value
let int_wire_value value = IntValue value
let bool_wire_value value = BoolValue value
let outliner_row_completed_ (row : Model.outline_row) =
  match row.row_status with
  | Some status ->
    (match status.ident with
     | Some ident ->
       String.ends_with ~suffix:".done" ident
       || String.ends_with ~suffix:".canceled" ident
     | None -> false)
  | None -> false

let outliner_row_id_wire_value (row : Model.outline_row) =
  StringValue row.row_uuid

let outliner_row_completed_wire_value row =
  BoolValue (outliner_row_completed_ row)

let extension_string values name =
  match String_map.find_opt name values with
  | Some (StringValue value) -> value
  | _ -> ""

let extension_int values name =
  match String_map.find_opt name values with
  | Some (IntValue value) -> value
  | _ -> 0

let navigation_path_depth path = List.length path

let handle_native_navigation_event input_event send =
  match input_event with
  | ExtensionEvent (_node, _identifier, "back", values) ->
    send (Model.BackAppNavigation (extension_int values "count"))
  | ExtensionEvent (_node, _identifier, "viewport-changed", values) ->
    send (Model.ApplyViewportWidth (extension_int values "width"))
  | ExtensionEvent (_node, _identifier, "dismiss-composer", _values) ->
    send Model.DismissComposer
  | _ -> true

let handle_native_search_event input_event send =
  match input_event with
  | ExtensionEvent (_node, _identifier, "back", values) ->
    send (Model.BackSearchNavigation (extension_int values "count"))
  | ExtensionEvent (_node, _identifier, "dismiss", _values) ->
    send Model.CloseSearch
  | ExtensionEvent (_node, _identifier, "query-changed", values) ->
    send (Model.ChangeSearchQuery (extension_string values "query"))
  | _ -> true


let handle_outliner_editor_event input_event block_id_source send =
  match input_event with
  | ExtensionEvent (_node, _identifier, name, values) ->
    let uuid = Signal.sample block_id_source in
    if name = "text-change" then
      send
        (Model.ChangeOutlinerText
           ( uuid
           , extension_string values "title"
           , extension_int values "caret-utf16-offset" ))
    else if name = "return" then
      send
        (Model.ReturnOutlinerEditor
           ( uuid
           , extension_string values "title"
           , extension_int values "caret-utf16-offset" ))
    else if name = "backspace" then
      send
        (Model.BackspaceOutlinerEditor
           ( uuid
           , extension_string values "title"
           , extension_int values "selection-length" ))
    else if name = "caret-change" then
      send
        (Model.MoveOutlinerCaret
           (uuid, extension_int values "caret-utf16-offset"))
    else true
  | _ -> true

let optional_string value =
  match value with
  | Some current -> current
  | None -> ""

let outliner_row_youtube_target (row : Model.outline_row) =
  optional_string row.youtube_target_url

let outliner_row_asset_type (row : Model.outline_row) =
  optional_string row.asset_type

let outliner_row_local_path (row : Model.outline_row) =
  optional_string row.local_path


let outliner_row_uuid (row : Model.outline_row) = row.row_uuid

let request_node_action (current : Model.logseq_model) uuid =
  if current.search_open then Model.RequestSearchNode uuid
  else Model.RequestAppNode uuid

let handle_outliner_block_content_event input_event model_source send =
  match input_event with
  | ExtensionEvent (_node, _identifier, name, values) ->
    if name = "open-node" then begin
      let uuid = extension_string values "uuid" in
      let current = Signal.sample model_source in
      send (request_node_action current uuid)
    end
    else if name = "drag-start" then
      send (Model.BeginOutlinerDrag (extension_string values "uuid"))
    else if name = "drop" then
      send
        (Model.DropOutlinerBlocks
           ( extension_string values "uuid"
           , extension_string values "placement" ))
    else if name = "edit" then
      send (Model.BeginOutlinerEdit (extension_string values "uuid"))
    else true
  | _ -> true

let graph_label (current : Model.logseq_model) =
  match current.selected_graph with
  | Some graph_name -> graph_name
  | None -> "No graph selected"

let sync_label (current : Model.logseq_model) =
  match current.sync_state with
  | OfflineState -> "Offline"
  | FailedState _ -> "Sync failed"
  | _ ->
    if
      current.has_pending_semantic_operations
      || current.has_pending_sync_request
    then "Syncing"
    else
      (match current.sync_state with
       | SyncedState -> "Up to date"
       | _ -> "Syncing")

let sync_indicator_label (current : Model.logseq_model) =
  match current.sync_state with
  | OfflineState -> "Not connected"
  | FailedState _ -> "Sync failed"
  | _ ->
    if
      current.has_pending_semantic_operations
      || current.has_pending_sync_request
    then "Syncing"
    else
      (match current.sync_state with
       | SyncedState -> "Synced"
       | SyncingState -> "Syncing"
       | _ -> "Not connected")

let sync_accessibility_identifier (current : Model.logseq_model) =
  match current.sync_state with
  | FailedState _ -> "sync.failed"
  | OfflineState -> "sync.disconnected"
  | _ -> "sync.connected"

let sync_indicator_foreground (current : Model.logseq_model) =
  match current.sync_state with
  | SyncedState
    when not current.has_pending_semantic_operations
         && not current.has_pending_sync_request -> "success-foreground"
  | _ -> "warning-foreground"

let sync_connection_label (current : Model.logseq_model) =
  match current.sync_state with
  | OfflineState | FailedState _ -> "Disconnected"
  | _ -> "Connected"

let sync_pending_label (current : Model.logseq_model) =
  if
    current.has_pending_semantic_operations
    || current.has_pending_sync_request
  then "Waiting to save"
  else "Saved"

let sync_cursor_label (current : Model.logseq_model) =
  match current.applied_server_t with
  | Some cursor -> string_of_int cursor
  | None -> "Unavailable"

let active_page_actions_visible_ (current : Model.logseq_model) =
  match Model.active_page current with
  | Some _ -> true
  | None -> false

let connection_settings_visible_ (current : Model.logseq_model) =
  not (active_page_actions_visible_ current)

let active_page_favorite_label (current : Model.logseq_model) =
  match Model.active_page current with
  | Some page ->
    if Model.page_is_favorite_ current page.uuid then "Unfavorite"
    else "Favorite"
  | None -> "Favorite"

let page_deletion_pending_ (current : Model.logseq_model) =
  current.pending_page_deletion <> None

let sign_out_pending_ (current : Model.logseq_model) =
  current.pending_sign_out

let sidebar_page_identifier (page : Model.sidebar_page) =
  "link.sidebar.page." ^ page.uuid

let sidebar_page_title (page : Model.sidebar_page) = page.title
let sidebar_graph_identifier (graph : Model.graph) = "menu.graph." ^ graph.id
let graph_title (graph : Model.graph) = graph.name

let sidebar_graph_selected_ (current : Model.logseq_model)
    (graph : Model.graph) =
  match current.selected_graph_id with
  | Some graph_id -> graph_id = graph.id
  | None -> false

let sidebar_graph_disabled_ (graph : Model.graph) = not graph.is_ready
let favorites_empty_ (current : Model.logseq_model) = current.favorites = []

let recent_pages_empty_ (current : Model.logseq_model) =
  current.recent_pages = []

let sidebar_favorites (current : Model.logseq_model) = current.favorites
let sidebar_recent_pages (current : Model.logseq_model) = current.recent_pages
let model_task_statuses (current : Model.logseq_model) = current.task_statuses

let model_outliner_autocomplete_candidates (current : Model.logseq_model) =
  current.outliner_autocomplete_candidates

let model_composer_assets (current : Model.logseq_model) =
  current.composer_assets

let model_language_choices (current : Model.logseq_model) =
  current.language_choices

let model_community_links (current : Model.logseq_model) =
  current.community_links

let model_graph_menu_open_ (current : Model.logseq_model) =
  current.graph_menu_open

let model_task_status_picker_open_ (current : Model.logseq_model) =
  current.task_status_picker_open

let model_attachment_picker_open_ (current : Model.logseq_model) =
  current.attachment_picker_open

let model_new_graph_name (current : Model.logseq_model) = current.new_graph_name

let model_new_graph_encrypted_ (current : Model.logseq_model) =
  current.new_graph_encrypted

let model_graph_password (current : Model.logseq_model) =
  current.graph_password

let model_graphs (current : Model.logseq_model) =
  let recent = Hashtbl.create 16 in
  List.iteri (fun index id -> Hashtbl.replace recent id index) current.recent_graph_ids;
  let local = Hashtbl.create 16 in
  List.iter (fun id -> Hashtbl.replace local id ()) current.local_graph_ids;
  let rank (graph : Model.graph) =
    (if Hashtbl.mem local graph.id then 0 else 1),
    Option.value ~default:max_int (Hashtbl.find_opt recent graph.id) in
  List.stable_sort (fun a b -> compare (rank a) (rank b)) current.graphs

let model_settings_language_menu_open_ (current : Model.logseq_model) =
  current.settings_language_menu_open

let model_settings_appearance_menu_open_ (current : Model.logseq_model) =
  current.settings_appearance_menu_open

let model_search_loading_ (current : Model.logseq_model) =
  current.search_loading

let model_search_query (current : Model.logseq_model) = current.search_query
let model_search_open_ (current : Model.logseq_model) = current.search_open
let model_settings_open_ (current : Model.logseq_model) = current.settings_open

let model_create_graph_open_ (current : Model.logseq_model) =
  current.create_graph_open

let model_graph_password_open_ (current : Model.logseq_model) =
  current.graph_password_open

let model_sync_details_open_ (current : Model.logseq_model) =
  current.sync_details_open

let journals_sidebar_selected_ (current : Model.logseq_model) =
  current.destination = JournalsDestination
  && current.selected_page = None

let flashcards_sidebar_selected_ (current : Model.logseq_model) =
  current.destination = FlashcardsDestination

let graphs_sidebar_selected_ (current : Model.logseq_model) =
  current.destination = GraphsDestination

let sidebar_page_selected_ (current : Model.logseq_model)
    (page : Model.sidebar_page) =
  current.destination = JournalsDestination
  && (match current.selected_page with
      | Some selected -> selected.uuid = page.uuid
      | None -> false)

let sidebar_tab_visible_ (current : Model.logseq_model) tab =
  Model.string_vector_contains_ current.sidebar_tabs tab

let flashcards_tab_visible_ (current : Model.logseq_model) =
  sidebar_tab_visible_ current "flashcards"

let graphs_tab_visible_ (current : Model.logseq_model) =
  sidebar_tab_visible_ current "graphs"

let composer_collapsed_ (current : Model.logseq_model) =
  not current.composer_expanded

let composer_send_disabled_ (current : Model.logseq_model) =
  String_kit.is_blank current.composer_draft
  && current.composer_assets = []

let task_status_identifier (status : Model.task_status) =
  "button.task-status.option." ^ status.uuid

let task_status_title (status : Model.task_status) = status.title

let task_status_style (status : Model.task_status) =
  let value =
    String.lowercase_ascii
      (match status.ident with
       | Some ident -> ident
       | None ->
         (match status.icon_id with
          | Some icon_id -> icon_id
          | None -> status.title))
  in
  if String_kit.includes value ~sub:"backlog" then "backlog"
  else if
    String_kit.includes value ~sub:"in-review"
    || String_kit.includes value ~sub:"inreview"
  then "in-review"
  else if
    String_kit.includes value ~sub:"doing"
    || String_kit.includes value ~sub:"inprogress"
    || String_kit.includes value ~sub:"progress"
  then "doing"
  else if
    String_kit.includes value ~sub:"done"
    || String_kit.includes value ~sub:"circle-check"
  then "done"
  else if
    String_kit.includes value ~sub:"cancel"
    || String_kit.includes value ~sub:"circle-x"
  then "canceled"
  else "todo"

let task_status_icon_name status =
  match task_status_style status with
  | "backlog" -> "app:task-backlog"
  | "doing" -> "app:task-doing"
  | "in-review" -> "app:task-review"
  | "done" -> "app:task-done"
  | "canceled" -> "app:task-canceled"
  | _ -> "app:task-todo"

let task_status_foreground (status : Model.task_status) =
  match status.icon_color with
  | Some color -> color
  | None -> "task-" ^ task_status_style status

let task_status_selected_ (current : Model.logseq_model) =
  current.selected_task_status <> None

let search_result_identifier (hit : Model.search_hit) =
  "search.result." ^ hit.hit_uuid

let search_result_title (hit : Model.search_hit) = hit.hit_title
let search_result_breadcrumb (hit : Model.search_hit) = hit.breadcrumb

let loaded_search_results (current : Model.logseq_model) =
  List.concat_map Fun.id (List.rev current.search_result_pages)

let page_search_results (current : Model.logseq_model) =
  List.filter (fun (hit : Model.search_hit) -> hit.is_page)
    (loaded_search_results current)

let block_search_results (current : Model.logseq_model) =
  List.filter (fun (hit : Model.search_hit) -> not hit.is_page)
    (loaded_search_results current)

let page_search_results_present_ (current : Model.logseq_model) =
  page_search_results current <> []

let block_search_results_present_ (current : Model.logseq_model) =
  block_search_results current <> []

let search_empty_state_present_ (current : Model.logseq_model) =
  (not current.search_loading) && current.search_result_count = 0

let search_results_present_ (current : Model.logseq_model) =
  current.search_result_count > 0

let search_result_status (current : Model.logseq_model) =
  if current.search_loading then "Searching…"
  else if String_kit.is_blank current.search_query then ""
  else begin
    let total = current.search_result_count in
    string_of_int total ^ (if current.search_has_more then "+" else "")
    ^ (if total = 1 then " result" else " results")
  end

let search_result_context_present_ (hit : Model.search_hit) =
  not (String_kit.is_blank hit.breadcrumb)

let search_empty_message (current : Model.logseq_model) =
  if String_kit.is_blank current.search_query then "Search your graph"
  else "No results"

let search_empty_supporting_message query =
  if String_kit.is_blank query then
    "Find pages and blocks by title or content."
  else "Try a different keyword."

let outliner_row_identifier (row : Model.outline_row) =
  "outliner.block." ^ row.row_uuid

let outliner_row_breadcrumbs (row : Model.outline_row) = row.row_breadcrumbs
let outliner_row_tags (row : Model.outline_row) = row.tags

let outliner_row_action_identifier (row : Model.outline_row) =
  "outliner.block-action." ^ row.row_uuid

let outliner_row_title (row : Model.outline_row) = row.row_title
let outliner_row_indent (row : Model.outline_row) = row.depth * 22
let outliner_row_has_children (row : Model.outline_row) = row.has_children

let outliner_row_zoom_label (row : Model.outline_row) =
  "Zoom into "
  ^ (if row.row_title = "" then "Untitled block" else row.row_title)

let outliner_row_zoom_identifier (row : Model.outline_row) =
  "button.outliner.zoom." ^ row.row_uuid ^ "."
  ^ (if row.row_title = "" then "Untitled block" else row.row_title)

let outliner_row_action_label (current : Model.logseq_model)
    (row : Model.outline_row) =
  (if current.outliner_selected_block_ids = [] then "Edit block "
   else "Select block ")
  ^ (if row.row_title = "" then "Untitled block" else row.row_title)

let outliner_row_collapse_label (row : Model.outline_row) =
  (if row.is_collapsed then "Expand " else "Collapse ")
  ^ (if row.row_title = "" then "Untitled block" else row.row_title)

let outliner_row_collapse_glyph (row : Model.outline_row) =
  if row.is_collapsed then "›" else "⌄"

let outliner_collapse_icon_name collapsed =
  if collapsed then "app:chevron-right" else "app:chevron-down"

let outliner_collapse_identifier (row : Model.outline_row) =
  "button.outliner.collapse." ^ row.row_uuid

let row_editing_ (current : Model.logseq_model) (row : Model.outline_row) =
  match current.outliner_editing with
  | Some editing -> editing.editing_uuid = row.row_uuid
  | None -> false

let row_not_editing_ current row = not (row_editing_ current row)

let string_vector_contains_ values target =
  List.exists (fun (value : string) -> value = target) values

let row_selected_ (current : Model.logseq_model) (row : Model.outline_row) =
  string_vector_contains_ current.outliner_selected_block_ids row.row_uuid

let outliner_selection_active_ (current : Model.logseq_model) =
  current.outliner_selected_block_ids <> []

let outliner_selection_inactive_ (current : Model.logseq_model) =
  current.outliner_selected_block_ids = []

let outliner_editor_active_ (current : Model.logseq_model) =
  outliner_selection_inactive_ current && current.outliner_editing <> None

let outliner_autocomplete_active_ (current : Model.logseq_model) =
  outliner_editor_active_ current
  &&
  (match current.outliner_autocomplete with
   | Some _ -> current.outliner_autocomplete_candidates <> []
   | None -> false)

let outliner_autocomplete_identifier
    (candidate : Model.outliner_autocomplete_candidate) =
  "button.outliner.autocomplete." ^ string_of_int candidate.candidate_index

let outliner_autocomplete_label
    (candidate : Model.outliner_autocomplete_candidate) =
  candidate.candidate_label

let node_navigation_active_ (current : Model.logseq_model) =
  current.app_navigation_path <> []

let node_navigation_inactive_ (current : Model.logseq_model) =
  current.app_navigation_path = []

let journals_destination_ (current : Model.logseq_model) =
  current.destination = JournalsDestination

let flashcards_destination_ (current : Model.logseq_model) =
  current.destination = FlashcardsDestination

let graphs_destination_ (current : Model.logseq_model) =
  current.destination = GraphsDestination

let graph_selected_ (current : Model.logseq_model) =
  current.selected_graph_id <> None || current.selected_graph <> None

let graph_picker_visible_ (current : Model.logseq_model) =
  journals_destination_ current
  && (not current.graph_loading)
  && not (graph_selected_ current)

let graph_loading_visible_ (current : Model.logseq_model) =
  journals_destination_ current && current.graph_loading
  && current.outliner_rows = []

let graph_loading_message (current : Model.logseq_model) =
  if graph_selected_ current then "Loading journals" else "Loading graphs"

let selected_graph_local_ (current : Model.logseq_model) =
  match current.selected_graph_id with
  | Some graph_id -> Model.graph_local_ current graph_id
  | None -> false

let journal_route_active_ (current : Model.logseq_model) =
  journals_destination_ current && graph_selected_ current
  && ((not current.graph_loading) || current.outliner_rows <> [])
  && node_navigation_inactive_ current

let journal_root_visible_ (current : Model.logseq_model) =
  journal_route_active_ current && not current.search_open

let selected_page_present_ (current : Model.logseq_model) =
  current.selected_page <> None

let selected_page_absent_ (current : Model.logseq_model) =
  not (selected_page_present_ current)

let journal_home_visible_ (current : Model.logseq_model) =
  journal_root_visible_ current && selected_page_absent_ current

let selected_page_visible_ (current : Model.logseq_model) =
  journal_root_visible_ current && selected_page_present_ current

let selected_page_models (current : Model.logseq_model) =
  if selected_page_visible_ current then [ current ] else []

let selected_page_model_key (current : Model.logseq_model) =
  match current.selected_page with
  | Some page -> page.uuid
  | None -> ""

let journal_tree_retained_ (current : Model.logseq_model) =
  graph_selected_ current
  && ((not current.graph_loading) || current.outliner_rows <> [])

let older_journals_visible_ (current : Model.logseq_model) =
  journal_root_visible_ current && current.has_older_journals
  && current.selected_page = None
  && not current.graph_loading
  && not (Model.load_older_journals_active_ current)

let journal_section_marker_for markers block_id =
  List.find_opt
    (fun (marker : Model.journal_section_marker) ->
      marker.block_id = block_id)
    markers

let outliner_journal_marker (current : Model.logseq_model)
    (row : Model.outline_row) =
  journal_section_marker_for current.outliner_section_markers row.row_uuid

let outliner_journal_heading_visible_ (current : Model.logseq_model) row =
  journal_root_visible_ current
  &&
  (match current.selected_page with
   | None -> outliner_journal_marker current row <> None
   | Some _ -> false)

let outliner_journal_divider_visible_ (current : Model.logseq_model) row =
  match outliner_journal_marker current row with
  | Some marker -> marker.has_divider
  | None -> false

let outliner_journal_title (current : Model.logseq_model) row =
  match outliner_journal_marker current row with
  | Some marker -> marker.section_title
  | None -> ""

let outliner_journal_page_id (current : Model.logseq_model) row =
  match outliner_journal_marker current row with
  | Some marker -> marker.page_id
  | None -> ""

let outliner_journal_button_identifier current row =
  "button.journal." ^ outliner_journal_page_id current row

let outliner_journal_accessibility_label current row =
  "Open " ^ outliner_journal_title current row

let node_screen_visible_ (current : Model.logseq_model) =
  journals_destination_ current && node_navigation_active_ current

let primary_sidebar_button_visible_ (current : Model.logseq_model) =
  (not (node_screen_visible_ current))
  && (not (graph_loading_visible_ current))
  && (not (graph_picker_visible_ current))
  && (not current.search_open)
  && current.authentication_state <> "signedOut"
  && current.authentication_state <> "signingIn"

let sidebar_drag_disabled_ (current : Model.logseq_model) =
  (not current.sidebar_open)
  && ((not (primary_sidebar_button_visible_ current))
      || current.app_navigation_path <> []
      || outliner_editor_active_ current
      || outliner_selection_active_ current)

let connection_control_visible_ (current : Model.logseq_model) =
  (not current.search_open)
  && (not (graph_picker_visible_ current))
  && current.authentication_state <> "signedOut"
  && current.authentication_state <> "signingIn"

let search_query_present_ (current : Model.logseq_model) =
  current.search_query <> ""

let bottom_chrome_presentation (current : Model.logseq_model) =
  if outliner_selection_active_ current then "outliner-selection"
  else if outliner_editor_active_ current then "outliner-editor"
  else if
    journals_destination_ current
    && (not current.search_open)
    && (not (graph_loading_visible_ current))
    && not (graph_picker_visible_ current)
  then
    if current.composer_expanded then "expanded-composer"
    else "capture-and-search"
  else "hidden"

let bottom_chrome_selection_ (current : Model.logseq_model) =
  bottom_chrome_presentation current = "outliner-selection"

let search_editor_active_ (current : Model.logseq_model) =
  current.search_open && current.search_navigation_path <> []
  && outliner_editor_active_ current

let bottom_chrome_editor_ (current : Model.logseq_model) =
  bottom_chrome_presentation current = "outliner-editor"

let bottom_chrome_expanded_composer_ (current : Model.logseq_model) =
  bottom_chrome_presentation current = "expanded-composer"

let bottom_chrome_capture_and_search_ (current : Model.logseq_model) =
  bottom_chrome_presentation current = "capture-and-search"

let bottom_chrome_occupies_layout_space_ (current : Model.logseq_model) =
  bottom_chrome_editor_ current

let active_node_projection (current : Model.logseq_model) =
  Model.last_opt current.node_routes

let node_projection_identifier (route : Model.node_projection) =
  route.node_uuid

let active_node_uuid (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route -> route.node_uuid
  | None -> ""

let active_node_breadcrumbs (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route when route.node_breadcrumbs <> [] -> route.node_breadcrumbs
  | Some route ->
    (match List.find_opt (fun (row : Model.outline_row) -> row.row_uuid = route.node_uuid) route.node_outliner_rows with
     | Some row -> row.row_breadcrumbs | None -> [])
  | None -> []

let active_node_has_breadcrumbs_ (current : Model.logseq_model) =
  active_node_breadcrumbs current <> []

let active_node_title (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route -> route.node_title
  | None -> "Untitled"

let outliner_scroll_identity (current : Model.logseq_model) =
  let graph = Option.value ~default:"local" current.selected_graph_id in
  let destination = match active_node_projection current, current.selected_page with
    | Some route, _ -> "node:" ^ route.node_uuid
    | None, Some page -> "page:" ^ page.uuid
    | None, None -> "journals" in
  graph ^ ":" ^ destination

let main_title (current : Model.logseq_model) =
  if current.destination = FlashcardsDestination then "Flashcards"
  else if current.destination = GraphsDestination then "Graphs"
  else
    match Model.active_page current with
    | Some page -> page.title
    | None -> ""

let current_content_active_ (current : Model.logseq_model) =
  match active_node_projection current with
  | Some _ -> true
  | None -> current.selected_page <> None

let current_content_is_tag_ (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route -> route.node_is_tag
  | None -> current.selected_page_is_tag

let current_content_is_property_ (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route -> route.node_is_property
  | None -> current.selected_page_is_property

let active_node_page_uuid (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route -> route.node_page_uuid
  | None ->
    (match current.selected_page with
     | Some page -> page.uuid
     | None -> "")

let active_node_related_rows (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route -> route.node_related_rows
  | None -> current.related_rows

let active_node_linked_reference_rows (current : Model.logseq_model) =
  match active_node_projection current with
  | Some route -> route.node_linked_reference_rows
  | None -> current.linked_reference_rows

let node_related_section_visible_ (current : Model.logseq_model) =
  current_content_active_ current
  && (not (current_content_is_tag_ current))
  && active_node_related_rows current <> []

let node_tag_section_visible_ (current : Model.logseq_model) =
  current_content_active_ current && current_content_is_tag_ current

let node_tag_section_empty_ (current : Model.logseq_model) =
  node_tag_section_visible_ current && active_node_related_rows current = []

let node_linked_reference_section_visible_ (current : Model.logseq_model) =
  not (node_tag_section_visible_ current)
  && active_node_linked_reference_rows current <> []

let page_content_ready_ (current : Model.logseq_model) =
  active_node_projection current <> None || current.selected_page_ready

let page_loading_visible_ (current : Model.logseq_model) =
  current_content_active_ current && not (page_content_ready_ current)
  && current.outliner_rows = [] && current.effect_error = None

let node_can_add_first_block_ (current : Model.logseq_model) =
  current_content_active_ current && page_content_ready_ current
  && current.outliner_rows = []
  && (not (current_content_is_tag_ current))
  && not (current_content_is_property_ current)
  && (match Model.active_page current with
      | Some page -> String.lowercase_ascii page.title <> "library"
      | None -> true)

let node_outliner_visible_ (current : Model.logseq_model) =
  current.outliner_rows <> []

let node_title_visible_ (current : Model.logseq_model) =
  node_outliner_visible_ current
  && (not (current_content_is_tag_ current))
  && (not
        (active_node_uuid current <> active_node_page_uuid current))

let main_can_add_first_block_ (current : Model.logseq_model) =
  journal_root_visible_ current && node_can_add_first_block_ current

let main_related_section_visible_ (current : Model.logseq_model) =
  journal_root_visible_ current && node_related_section_visible_ current

let main_tag_section_visible_ (current : Model.logseq_model) =
  journal_root_visible_ current && node_tag_section_visible_ current

let main_linked_reference_section_visible_ (current : Model.logseq_model) =
  journal_root_visible_ current
  && node_linked_reference_section_visible_ current

let outliner_row_has_breadcrumb_ (row : Model.outline_row) =
  row.row_breadcrumb <> ""

let outliner_row_breadcrumb (row : Model.outline_row) = row.row_breadcrumb

let outliner_row_structured_breadcrumb_ (row : Model.outline_row) =
  row.row_breadcrumbs <> []

let outliner_row_fallback_breadcrumb_ (row : Model.outline_row) =
  row.row_breadcrumbs = [] && outliner_row_has_breadcrumb_ row

let breadcrumb_identifier (breadcrumb : Model.sidebar_page) =
  "button.breadcrumb." ^ breadcrumb.uuid

let breadcrumb_title (breadcrumb : Model.sidebar_page) = breadcrumb.title

let editing_title (current : Model.logseq_model) =
  match current.outliner_editing with
  | Some editing -> editing.editing_title
  | None -> ""

let editing_caret (current : Model.logseq_model) =
  match current.outliner_editing with
  | Some editing -> editing.caret_utf16_offset
  | None -> 0

let outliner_row_has_status_ (row : Model.outline_row) =
  row.row_status <> None

let outliner_row_status_title (row : Model.outline_row) =
  match row.row_status with
  | Some status -> status.title
  | None -> ""

let outliner_task_status_icon (row : Model.outline_row) =
  match row.row_status with
  | Some status -> task_status_icon_name status
  | None -> "app:task-todo"

let outliner_task_status_style_is_ (row : Model.outline_row) expected =
  match row.row_status with
  | Some status -> task_status_style status = expected
  | None -> expected = "todo"

let outliner_task_status_backlog_ row =
  outliner_task_status_style_is_ row "backlog"

let outliner_task_status_todo_ row =
  outliner_task_status_style_is_ row "todo"

let outliner_task_status_doing_ row =
  outliner_task_status_style_is_ row "doing"

let outliner_task_status_review_ row =
  outliner_task_status_style_is_ row "in-review"

let outliner_task_status_done_ row =
  outliner_task_status_style_is_ row "done"

let outliner_task_status_canceled_ row =
  outliner_task_status_style_is_ row "canceled"

let outliner_editor_task_label (current : Model.logseq_model) =
  match current.outliner_editing with
  | Some editing ->
    (match
       Model.row_index current.outliner_rows editing.editing_uuid
     with
     | Some index ->
       "Task: "
       ^
       (match (List.nth current.outliner_rows index).row_status with
        | Some status -> status.title
        | None -> "None")
     | None -> "Task: None")
  | None -> "Task: None"

let outliner_row_has_tags_ (row : Model.outline_row) = row.tags <> []

let outliner_row_sync_failed_ (row : Model.outline_row) =
  row.sync_status = Some "failed"

let outliner_row_list_item_press_enabled_ host (row : Model.outline_row) =
  host <> KotlinHost || row.is_asset || row.opens_as_page

let outliner_tag_identifier (tag : Model.sidebar_page) =
  "button.block-tag." ^ tag.uuid

let outliner_tag_title (tag : Model.sidebar_page) = "#" ^ tag.title

let outliner_row_journal_ (current : Model.logseq_model) row =
  journal_root_visible_ current
  && outliner_journal_marker current row <> None

let composer_asset_title (asset : Model.composer_asset) = asset.title
let composer_asset_path (asset : Model.composer_asset) = asset.local_path

let composer_asset_identifier (asset : Model.composer_asset) =
  "composer.asset." ^ asset.uuid

let composer_assets_present_ (current : Model.logseq_model) =
  current.composer_assets <> []

(* Matches the platform image-asset policy: extensions the Apple backend can
   thumbnail through CGImageSource (including PDF and TIFF first pages). The
   Kotlin image codec cannot decode PDF or TIFF, so those fall back to the
   document tile there. *)
let composer_asset_is_image (context : Lui_ui.ui_context)
    (asset : Model.composer_asset) =
  let extension =
    match String.rindex_opt asset.local_path '.' with
    | Some index when index < String.length asset.local_path - 1 ->
      String.lowercase_ascii
        (String.sub asset.local_path (index + 1)
           (String.length asset.local_path - index - 1))
    | _ -> ""
  in
  let kotlin_image_codecs =
    Lui_ui.host context = Lui_protocol.KotlinHost
  in
  List.mem extension
    (if kotlin_image_codecs then
       [ "png"; "jpg"; "jpeg"; "gif"; "webp"; "bmp"; "wbmp"; "heic"; "heif"
       ; "avif" ]
     else
       [ "png"; "jpg"; "jpeg"; "gif"; "webp"; "bmp"; "wbmp"; "heic"; "heif"
       ; "avif"; "tif"; "tiff"; "pdf" ])

let asset_preview_ (current : Model.logseq_model) =
  current.asset_preview <> None

let asset_preview_path (current : Model.logseq_model) =
  match current.asset_preview with
  | Some preview -> preview.preview_path
  | None -> ""

let composer_expanded_ (current : Model.logseq_model) = current.composer_expanded
let composer_draft (current : Model.logseq_model) = current.composer_draft
let composer_autofocus_ (current : Model.logseq_model) = current.composer_autofocus

let outliner_task_status_option_identifier (status : Model.task_status) =
  "button.block-task-status-option."
  ^ (match status.ident with
      | Some ident -> ident
      | None -> status.uuid)

let first_flashcard (current : Model.logseq_model) =
  match current.flashcards with
  | card :: _ -> Some card
  | [] -> None

let flashcards_empty_ (current : Model.logseq_model) = current.flashcards = []
let flashcards_present_ (current : Model.logseq_model) = current.flashcards <> []

let flashcard_question (current : Model.logseq_model) =
  match first_flashcard current with
  | Some card ->
    if current.flashcard_cloze_revealed then card.question_revealed
    else card.question_hidden
  | None -> ""

let flashcard_remaining_label (current : Model.logseq_model) =
  string_of_int (List.length current.flashcards) ^ " remaining"

let flashcard_show_cloze_ (current : Model.logseq_model) =
  match first_flashcard current with
  | Some card -> card.has_cloze && not current.flashcard_cloze_revealed
  | None -> false

let flashcard_show_answer_ (current : Model.logseq_model) =
  match first_flashcard current with
  | Some card ->
    ((not card.has_cloze) || current.flashcard_cloze_revealed)
    && not current.flashcard_answer_revealed
  | None -> false

let flashcard_show_ratings_ (current : Model.logseq_model) =
  flashcards_present_ current && current.flashcard_answer_revealed

let visible_flashcard_answer_rows (current : Model.logseq_model) =
  if current.flashcard_answer_revealed then
    match first_flashcard current with
    | Some card -> card.answer_rows
    | None -> []
  else []

let flashcard_answer_rows_visible_ (current : Model.logseq_model) =
  visible_flashcard_answer_rows current <> []

let flashcard_answer_identifier (answer : Model.flashcard_answer_row) =
  "flashcard.answer." ^ string_of_int answer.answer_index

let flashcard_answer_text (answer : Model.flashcard_answer_row) =
  answer.answer_text

let graph_identifier (graph : Model.graph) = "graph." ^ graph.id
let graph_delete_identifier (graph : Model.graph) =
  "button.graph.delete." ^ graph.id

let graph_status_identifier (graph : Model.graph) =
  "graph.status." ^ graph.id

let graph_status_visible_ (graph : Model.graph) =
  graph.is_encrypted || not graph.is_ready

let graph_status_title (graph : Model.graph) =
  if graph.is_encrypted then "Encrypted"
  else "Graph is not ready for sync."

let graph_not_ready_ (graph : Model.graph) = not graph.is_ready

let graph_row_disabled_ (current : Model.logseq_model) (graph : Model.graph) =
  graph_not_ready_ graph || Model.graph_delete_active_ current graph.id

let graph_delete_active_ (current : Model.logseq_model) (graph : Model.graph) =
  Model.graph_delete_active_ current graph.id

let graph_row_local_ (current : Model.logseq_model) (graph : Model.graph) =
  Model.graph_local_ current graph.id

let graph_icon_name local (graph : Model.graph) =
  if local then "app:graph-local" else "app:graph-remote"

let sidebar_graph_icon_name (current : Model.logseq_model) (graph : Model.graph) =
  if graph.is_encrypted then "app:graph-locked"
  else graph_icon_name (Model.graph_local_ current graph.id) graph

let graph_shared_ (graph : Model.graph) =
  match graph.role with
  | Some role -> role <> "" && role <> "manager"
  | None -> false

let local_graphs (current : Model.logseq_model) =
  List.filter (fun (graph : Model.graph) ->
    not (graph_shared_ graph) && Model.graph_local_ current graph.id)
    (model_graphs current)

let remote_graphs (current : Model.logseq_model) =
  List.filter (fun (graph : Model.graph) ->
    not (graph_shared_ graph) && not (Model.graph_local_ current graph.id))
    (model_graphs current)

let shared_graphs (current : Model.logseq_model) =
  List.filter graph_shared_ (model_graphs current)

let shared_graphs_present_ current = shared_graphs current <> []

let local_graphs_empty_ (current : Model.logseq_model) =
  local_graphs current = []

let graphs_empty_ (current : Model.logseq_model) = current.graphs = []
let graphs_present_ (current : Model.logseq_model) = current.graphs <> []

let remote_graphs_present_ (current : Model.logseq_model) =
  remote_graphs current <> []

let new_graph_name_empty_ (current : Model.logseq_model) =
  String_kit.is_blank current.new_graph_name

let graph_create_disabled_ (current : Model.logseq_model) =
  new_graph_name_empty_ current || Model.graph_create_active_ current
  || Model.graph_creation_password_invalid_ current

let empty_graphs_loading_ (current : Model.logseq_model) =
  graphs_empty_ current && Model.graph_refresh_active_ current

let empty_graphs_refreshable_ (current : Model.logseq_model) =
  graphs_empty_ current && not (Model.graph_refresh_active_ current)

let graph_deletion_pending_ (current : Model.logseq_model) =
  current.pending_graph_deletion <> None

let graph_deletion_message (current : Model.logseq_model) =
  match current.pending_graph_deletion with
  | Some graph ->
    "Are you sure you want to permanently delete the graph \"" ^ graph.name
    ^ "\" from Logseq?"
  | None -> ""

let graph_password_empty_ (current : Model.logseq_model) =
  String_kit.is_blank current.graph_password

let graph_unlock_disabled_ (current : Model.logseq_model) =
  graph_password_empty_ current || Model.graph_unlock_active_ current

let effect_error_present_ (current : Model.logseq_model) =
  match current.effect_error with
  | Some message -> message <> ""
  | None -> false

let effect_error_message (current : Model.logseq_model) =
  match current.effect_error with
  | Some message -> message
  | None -> ""

let graph_unlock_error_present_ (current : Model.logseq_model) =
  effect_error_present_ current

let graph_unlock_error_message (current : Model.logseq_model) =
  match effect_error_message current with
  | "authenticationFailure" -> "Incorrect password."
  | message -> message

let global_effect_error_present_ (current : Model.logseq_model) =
  effect_error_present_ current
  && (not current.graph_password_open)
  && current.authentication_state <> "signedOut"
  && current.authentication_state <> "signingIn"
  &&
  (match current.sync_state with
   | FailedState _ -> false
   | _ -> true)

let graph_picker_error_reason (current : Model.logseq_model) =
  match current.effect_error with
  | Some reason -> Some reason
  | None ->
    (match current.sync_state with
     | FailedState reason -> Some reason
     | _ -> None)

let graph_picker_error_present_ (current : Model.logseq_model) =
  graph_picker_error_reason current <> None

let graphs_screen_error_visible_ (current : Model.logseq_model) =
  graph_picker_error_present_ current
  && not (global_effect_error_present_ current)

let error_separator reason =
  match String_kit.index_of ~sub:"\n" reason with
  | Some index -> index
  | None -> -1

let graph_picker_error_code (current : Model.logseq_model) =
  match graph_picker_error_reason current with
  | Some reason ->
    let separator = error_separator reason in
    if separator < 0 then "sync_failed" else String.sub reason 0 separator
  | None -> ""

let graph_picker_error_title (current : Model.logseq_model) =
  match graph_picker_error_code current with
  | "graph_discovery_failed" -> "Couldn't load graphs"
  | "graph_create_failed" -> "Couldn't create graph"
  | "graph_open_failed" -> "Couldn't open graph"
  | "graph_unlock_failed" -> "Couldn't unlock graph"
  | "graph_initial_upload_failed" -> "Couldn't upload graph"
  | "graph_key_provision_failed" -> "Couldn't prepare encryption"
  | "sync_failed" -> "Sync failed"
  | _ -> "Something went wrong"

let graph_picker_error_message (current : Model.logseq_model) =
  match graph_picker_error_reason current with
  | Some reason ->
    let separator = error_separator reason in
    if separator < 0 then reason
    else String.sub reason (separator + 1) (String.length reason - separator - 1)
  | None -> ""

let settings_main_visible_ (current : Model.logseq_model) =
  (not current.settings_tabs_open) && not current.runtime_log_open

let settings_spell_check (current : Model.logseq_model) = current.spell_check

let settings_auto_correction (current : Model.logseq_model) =
  current.auto_correction

let settings_base_url (current : Model.logseq_model) = current.base_url_draft

let settings_base_url_invalid_ (current : Model.logseq_model) =
  String.trim current.base_url_draft <> ""
  && not (Model.valid_base_url_ current.base_url_draft)

let settings_apply_disabled_ (current : Model.logseq_model) =
  not (Model.valid_base_url_ current.base_url_draft)

let settings_version (current : Model.logseq_model) = current.version
let settings_revision (current : Model.logseq_model) = current.revision

let settings_language_title (current : Model.logseq_model) =
  match
    Model.settings_language_by_id current.language_choices current.language
  with
  | Some choice -> choice.title
  | None -> "System"

let settings_appearance_title (current : Model.logseq_model) =
  match current.appearance with
  | "light" -> "Light"
  | "dark" -> "Dark"
  | _ -> "System"

let settings_language_choice_title (choice : Model.settings_language_choice) =
  choice.title

let settings_language_choice_identifier
    (choice : Model.settings_language_choice) =
  "button.settings.language." ^ choice.id

let settings_community_link_title (link : Model.settings_community_link) =
  link.title

let settings_community_link_identifier
    (link : Model.settings_community_link) =
  "link.settings.community." ^ link.id

let settings_community_link_needs_separator_ (current : Model.logseq_model)
    (link : Model.settings_community_link) =
  match Model.last_opt current.community_links with
  | Some final_link -> link.id <> final_link.id
  | None -> false

let settings_tabs_visible_ (current : Model.logseq_model) =
  current.settings_tabs_open

let settings_tab_title tab =
  match tab with
  | "journals" -> "Journals"
  | "flashcards" -> "Flashcards"
  | _ -> "Graphs"

let settings_tabs_summary (current : Model.logseq_model) =
  String.concat " · " (List.map settings_tab_title current.sidebar_tabs)

let runtime_log_visible_ (current : Model.logseq_model) =
  current.runtime_log_open

let tab_enabled_ (current : Model.logseq_model) tab =
  Model.string_vector_contains_ current.sidebar_tabs tab

let tab_toggle_label (current : Model.logseq_model) tab =
  let title = settings_tab_title tab in
  title ^ (if tab_enabled_ current tab then ", on" else ", off")

let tab_selection_glyph (current : Model.logseq_model) tab =
  if tab_enabled_ current tab then "✓" else "○"

let tab_selection_icon_name (current : Model.logseq_model) tab =
  if tab_enabled_ current tab then "app:selected" else "app:unselected"

let tab_selection_foreground (current : Model.logseq_model) tab =
  if tab_enabled_ current tab then "accent" else "secondary"

let tab_disabled_ (current : Model.logseq_model) tab =
  not (tab_enabled_ current tab)

let tab_index (current : Model.logseq_model) tab =
  let rec loop index tabs =
    match tabs with
    | [] -> -1
    | value :: rest -> if value = tab then index else loop (index + 1) rest
  in
  loop 0 current.sidebar_tabs

let tab_movement_visible_ (current : Model.logseq_model) tab =
  tab <> "journals" && tab_enabled_ current tab

let settings_flashcards_before_graphs_ (current : Model.logseq_model) =
  tab_enabled_ current "flashcards"
  && tab_index current "flashcards" < tab_index current "graphs"

let settings_flashcards_after_graphs_ (current : Model.logseq_model) =
  tab_enabled_ current "flashcards"
  && tab_index current "flashcards" > tab_index current "graphs"

let settings_available_tabs_present_ (current : Model.logseq_model) =
  not (tab_enabled_ current "flashcards")

let tab_move_up_disabled_ (current : Model.logseq_model) tab =
  tab_index current tab <= 1

let tab_move_down_disabled_ (current : Model.logseq_model) tab =
  let index = tab_index current tab in
  index < 0 || index >= List.length current.sidebar_tabs - 1

let tab_toggle_identifier tab = "toggle.settings.tab." ^ tab
let tab_up_identifier tab = "button.settings.tab." ^ tab ^ ".up"
let tab_down_identifier tab = "button.settings.tab." ^ tab ^ ".down"

let runtime_log_level (record : Model.runtime_log_record) = record.level

let runtime_log_timestamp (record : Model.runtime_log_record) =
  record.timestamp

let runtime_log_message (record : Model.runtime_log_record) = record.message
let runtime_log_error_ (record : Model.runtime_log_record) =
  record.level = "ERROR"

let runtime_log_empty_ (current : Model.logseq_model) =
  current.runtime_log_records = []

let runtime_log_records (current : Model.logseq_model) =
  current.runtime_log_records

let runtime_log_record_identifier (record : Model.runtime_log_record) =
  record.id

let runtime_log_errors_label (current : Model.logseq_model) =
  if current.runtime_log_errors_only then "All" else "Errors only"

let runtime_log_order_label (current : Model.logseq_model) =
  if current.runtime_log_newest_first then "Oldest first" else "Newest first"

let runtime_log_source_label (current : Model.logseq_model) =
  if current.runtime_log_source = "ui" then "Core log" else "UI log"

let sync_error_present_ (current : Model.logseq_model) =
  match current.sync_state with
  | FailedState _ -> true
  | _ -> false

let sync_error_message (current : Model.logseq_model) =
  match current.sync_state with
  | FailedState reason -> reason
  | _ -> ""

let selected_page_content_title_visible_ (current : Model.logseq_model) =
  selected_page_present_ current
  && (not current.selected_page_is_tag)
  && node_outliner_visible_ current

let selected_page_title (current : Model.logseq_model) =
  match current.selected_page with
  | Some page -> page.title
  | None -> ""

let navigation_root_model (current : Model.logseq_model) =
  { current with
    outliner_rows = (if current.node_routes = [] then current.outliner_rows else current.navigation_root_rows);
    node_routes = [];
    app_navigation_path = [];
    search_open = false;
    search_navigation_path = [];
  }

let journal_navigation_model (current : Model.logseq_model) =
  let rows = current.journal_outliner_rows in
  let root =
    {
      current with
      destination = JournalsDestination;
      selected_page = None;
      selected_page_is_tag = false;
      selected_page_is_property = false;
      related_rows = [];
      linked_reference_rows = [];
      node_routes = [];
      app_navigation_path = [];
      search_open = false;
      search_navigation_path = [];
      outliner_rows = rows;
      outliner_section_markers = Model.journal_section_markers rows;
    }
  in
  if current.node_routes = [] then root
  else
    {
      root with
      outliner_selected_block_ids = [];
      outliner_editing = None;
      outliner_autocomplete = None;
      outliner_autocomplete_candidates = [];
    }

let node_route_model (current : Model.logseq_model)
    (route : Model.node_projection) =
  {
    current with
    node_routes = [ route ];
    outliner_rows = route.node_outliner_rows;
    outliner_section_markers = [];
    outliner_selected_block_ids = route.node_outliner_selected_block_ids;
    outliner_editing = route.node_outliner_editing;
    outliner_autocomplete = route.node_outliner_autocomplete;
    outliner_autocomplete_candidates =
      route.node_outliner_autocomplete_candidates;
  }

let app_navigation_depth (current : Model.logseq_model) =
  navigation_path_depth current.app_navigation_path

(* Navigation levels platform back should settle: pushed routes plus one
   extra for editing, selection, or a non-journal pane so shell-edge back
   reaches BackAppNavigation instead of leaving the app. *)
let app_back_depth (current : Model.logseq_model) =
  app_navigation_depth current
  +
  if
    current.destination = JournalsDestination
    && current.outliner_selected_block_ids = []
    && current.outliner_editing = None
  then 0
  else 1

let search_navigation_depth (current : Model.logseq_model) =
  navigation_path_depth current.search_navigation_path

let search_node_routes (current : Model.logseq_model) =
  if not current.search_open then []
  else begin
    let routes = current.node_routes in
    let start = min (app_navigation_depth current) (List.length routes) in
    Model.sub_list start (List.length routes) routes
  end

let active_route_only routes =
  match Model.last_opt routes with
  | Some route -> [ route ]
  | None -> []

let active_app_node_routes (current : Model.logseq_model) =
  active_route_only (Model.app_node_routes current)

let active_search_node_routes (current : Model.logseq_model) =
  active_route_only (search_node_routes current)

let kotlin_app_root_visible_ (current : Model.logseq_model) =
  (not current.search_open) && active_app_node_routes current = []

let kotlin_search_root_visible_ (current : Model.logseq_model) =
  current.search_open && active_search_node_routes current = []

let authentication_screen_visible_ (current : Model.logseq_model) =
  current.authentication_state = "signedOut"
  || current.authentication_state = "signingIn"

let graph_picker_screen_visible_ (current : Model.logseq_model) =
  graph_picker_visible_ current
  && not (authentication_screen_visible_ current)

let authentication_signing_in_ (current : Model.logseq_model) =
  current.authentication_state = "signingIn"

let authentication_error_present_ (current : Model.logseq_model) =
  match current.authentication_error with
  | Some message -> message <> ""
  | None -> false

let authentication_error_message (current : Model.logseq_model) =
  match current.authentication_error with
  | Some message -> message
  | None -> ""

let graph_picker_hidden_ (current : Model.logseq_model) =
  not (graph_picker_visible_ current)

let main_screen_visible_ (current : Model.logseq_model) =
  graph_picker_hidden_ current
  && not (authentication_screen_visible_ current)

let application_shell_visible_ (current : Model.logseq_model) =
  not (authentication_screen_visible_ current)

let drawer_selected_ (current : Model.logseq_model) =
  current.sidebar_open && graph_picker_hidden_ current
  && not (authentication_screen_visible_ current)

let drawer_disabled_ (current : Model.logseq_model) =
  graph_picker_visible_ current
  || authentication_screen_visible_ current
  || sidebar_drag_disabled_ current

let with_label label (elem : Lui_elements.t) : Lui_elements.t =
 fun context parent ->
   let node = elem context parent in
   Lui_ui.string_property context node AccessibilityLabel label;
   node

let with_label_signal label (elem : Lui_elements.t) : Lui_elements.t =
 fun context parent ->
   let node = elem context parent in
   Lui_ui.string_property_signal context node AccessibilityLabel label;
   node

let with_selected_signal selected (elem : Lui_elements.t) : Lui_elements.t =
 fun context parent ->
   let node = elem context parent in
   Lui_ui.bool_property_signal context node Selected selected;
   node

let with_string_prop prop value (elem : Lui_elements.t) : Lui_elements.t =
 fun context parent ->
   let node = elem context parent in
   Lui_ui.string_property context node prop value;
   node

let with_string_prop_signal prop signal_ (elem : Lui_elements.t)
    : Lui_elements.t =
 fun context parent ->
   let node = elem context parent in
   Lui_ui.string_property_signal context node prop signal_;
   node

let with_bool_prop_signal prop signal_ (elem : Lui_elements.t)
    : Lui_elements.t =
 fun context parent ->
   let node = elem context parent in
   Lui_ui.bool_property_signal context node prop signal_;
   node

let with_int_prop_signal prop signal_ (elem : Lui_elements.t)
    : Lui_elements.t =
 fun context parent ->
   let node = elem context parent in
   Lui_ui.int_property_signal context node prop signal_;
   node

let with_liquid_glass shape (elem : Lui_elements.t) : Lui_elements.t =
 fun context parent ->
   match Lui_ui.profile context with
   | { Lui_protocol.profile_os = Lui_protocol.IOS;
       profile_host = Lui_protocol.SwiftUIHost;
     } ->
     let tweak = Lui_ui.platform_tweak context "liquid-glass" in
     Lui_ui.extension_property context tweak "shape"
       (StringValue shape);
     ignore (elem context (Some tweak));
     Lui_elements.attach context parent tweak;
     tweak
   | _ -> elem context parent

let with_reading_insets (elem : Lui_elements.t) : Lui_elements.t =
 fun context parent ->
   match Lui_ui.profile context with
   | { profile_os = IOS; profile_host = SwiftUIHost }
   | { profile_os = AndroidOS; profile_host = KotlinHost } ->
     let tweak = Lui_ui.platform_tweak context "native-adaptive-insets" in
     Lui_ui.extension_property context tweak "breakpoint" (IntValue Model.wide_content_breakpoint);
     Lui_ui.extension_property context tweak "wide-inset" (IntValue 16);
     ignore (elem context (Some tweak));
     Lui_elements.attach context parent tweak;
     tweak
   | _ -> elem context parent

let icon_of_wire_name (name : string) : Lui_elements.icon =
  if String_kit.starts_with ~prefix:"app:" name then
    `app (String.sub name 4 (String.length name - 4))
  else `app name
