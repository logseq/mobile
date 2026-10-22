module Json = Yojson.Basic
module Types = Session_types
module So = Session_outliner
module Pump = Pending_pump
module Rpc = Rpc
module Model = Cache_model
module Ops = Pending_ops
module Outliner = Outliner_state
module Effects = Outliner_effects

let default_options = Types.default_options
let create_session = Types.create_session
let state = Types.state
let host = Types.host
let now_ms = Types.now_ms
let debug = Types.debug
let fresh_squuid = Types.fresh_squuid
let projection_server_t = Types.projection_server_t
let submission_server_t = Types.submission_server_t
let record_accepted_server_t = Types.record_accepted_server_t
let transport_operation_block = Types.transport_operation_block
let empty_sidebar = Types.empty_sidebar
let sidebar_pages = So.sidebar_pages
let outliner_context_with_blocks = So.outliner_context_with_blocks
let base_outliner_context_live = So.base_outliner_context_live
let page_overlay = So.page_overlay
let scope_selected_page = So.scope_selected_page
let base_outliner_context_with_blocks = So.base_outliner_context_with_blocks
let base_outliner_context = So.base_outliner_context
let page_outliner_context = So.page_outliner_context
let node_route_context = So.node_route_context
let active_node_route = So.active_node_route
let node_route_related_blocks = So.node_route_related_blocks
let node_route_linked_reference_blocks =
  So.node_route_linked_reference_blocks
let page_for_visible_block = So.page_for_visible_block
let projected_node_destination = So.projected_node_destination
let with_extra_blocks = So.with_extra_blocks
let outliner_context = So.outliner_context
let project_outliner_operations = So.project_outliner_operations
let selected_graph = So.selected_graph
let selected_graph_is_encrypted = So.selected_graph_is_encrypted
let selected_graph_is_unlocked = So.selected_graph_is_unlocked
let selected_page_is_tag = So.selected_page_is_tag
let selected_page_is_property = So.selected_page_is_property
let snapshot_related_blocks = So.snapshot_related_blocks
let snapshot_linked_reference_blocks = So.snapshot_linked_reference_blocks
let has_pending_operations = So.has_pending_operations
let reset_outliner = So.reset_outliner
let clear_node_navigation = So.clear_node_navigation
let persist_active_node_state = So.persist_active_node_state
let initial_node_state = So.initial_node_state
let push_node_route = So.push_node_route
let pop_node_route = So.pop_node_route
let aggregate_return_context = So.aggregate_return_context
let refresh_reference_metadata = So.refresh_reference_metadata
let event_patch_plan = So.event_patch_plan
let pending_request_json = Pump.pending_request_json
let pending_block_unchanged = Pump.pending_block_unchanged
let mark_pending_failed = Pump.mark_pending_failed
let set_pending_active = Pump.set_pending_active
let encrypted_title = Pump.encrypted_title
let prepare_pending_create_request = Pump.prepare_pending_create_request
let prepare_pending_creation = Pump.prepare_pending_creation
let prepare_pending_block = Pump.prepare_pending_block
let prepare_pending_next = Pump.prepare_pending_next
let activate_semantic_request = Pump.activate_semantic_request
let enqueue_semantic = Pump.enqueue_semantic
let normalize_operation_titles = Pump.normalize_operation_titles
let capture_operations = Pump.capture_operations
let enqueue_capture = Pump.enqueue_capture
let restore_semantic_queue = Pump.restore_semantic_queue
let begin_pending_sync = Pump.begin_pending_sync
let finish_semantic_active = Pump.finish_semantic_active
let cleanup_pending_active = Pump.cleanup_pending_active
let finish_pending_block = Pump.finish_pending_block
let asset_datoms_operation = Pump.asset_datoms_operation
let reconcile_created_block = Pump.reconcile_created_block
let complete_pending_active = Pump.complete_pending_active
let accepted_transaction = Pump.accepted_transaction
let completion_error = Pump.completion_error
let parse_semantic_completion = Pump.parse_semantic_completion
let parse_transport_completion = Pump.parse_transport_completion
let complete_pending_sync = Pump.complete_pending_sync
let cancel_pending_sync = Pump.cancel_pending_sync

let node_icon session uuid =
  Option.bind (host session).Types.graph_node_icon (fun resolve -> resolve uuid)

let query_db session =
  match (host session).Types.graph_db with
  | Some load -> load ()
  | None -> Some (state session).model.db

let current_summary session (summary : Model.entity_summary) =
  match Option.bind (query_db session) (fun db ->
    Option.bind (Datascript.entid db "block/uuid" (Datascript.Uuid summary.uuid)) (fun eid ->
      Option.bind (Graph_read.int_value (Graph_read.value db eid "block/journal-day")) (fun day ->
        if Journal.valid_day day then Some (Journal.title db day) else None))) with
  | Some title -> {summary with title}
  | None -> summary

let summary_json session summary = Rpc.summary_json (current_summary session summary)

let result_block_encoder db =
  let presentation = Node_presentation.decorate db in
  let pages = Hashtbl.create 4 in
  let encode_tree block =
    let children = match Hashtbl.find_opt pages block.Model.page_id with
      | Some children -> children
      | None ->
        let children = Hashtbl.create 16 in
        List.iter (fun (block : Model.block) -> Option.iter (fun parent ->
          let siblings = Option.value ~default:[] (Hashtbl.find_opt children parent) in
          Hashtbl.replace children parent (block :: siblings)) block.parent_id)
          (Graph_read.blocks_for_page (fun text -> Ok text) db block.page_id);
        Hashtbl.iter (fun parent blocks -> Hashtbl.replace children parent
          (List.sort Outliner.compare_blocks blocks)) children;
        Hashtbl.replace pages block.page_id children;
        children in
    let rec encode ancestors depth (block : Model.block) =
      if depth > 128 then invalid_arg "Result block nesting is too deep";
      let descendants = Option.value ~default:[] (Hashtbl.find_opt children block.uuid)
        |> List.filter (fun (child : Model.block) -> not (Outliner.Sset.mem child.uuid ancestors)) in
      let ancestors = Outliner.Sset.add block.uuid ancestors in
      match presentation block.uuid (Rpc.block_json block) with
      | `Assoc fields -> `Assoc (("children", `List (List.map (encode ancestors (depth + 1)) descendants)) :: fields)
      | value -> value in
    encode Outliner.Sset.empty 0 block in
  encode_tree

let query_for session db uuid =
  let current_page = match active_node_route session with
    | Some route -> Some (current_summary session route.Types.page).title
    | None -> Option.map (fun (page : Model.entity_summary) -> (current_summary session page).title)
        (state session).selected_sidebar_page in
  let encode_tree = result_block_encoder db in
  Query_block.render ?current_page db uuid
  |> Option.map (fun result ->
      try
        let views = Result_view.render_rows db ~owner:uuid ~feature:"query-result" ~encode_block:encode_tree result.Query_block.rows in
        (match Query_block.to_yojson encode_tree result, views with
         | `Assoc fields, `Assoc view_fields -> `Assoc (fields @ view_fields)
         | value, _ -> value)
      with error -> Query_block.to_yojson Rpc.block_json
        {result with Query_block.rows = []; error = Some (Printexc.to_string error)})

let object_views_for session owner is_tag is_property =
  if not is_tag && not is_property then `Null
  else match query_db session with
  | None -> `Null
  | Some db ->
    let feature = if is_tag then "class-objects" else "property-objects" in
    match Result_view.render db ~owner ~feature ~encode_block:(result_block_encoder db) with
    | Ok value -> value
    | Error message -> `Assoc ["ownerUuid", `String owner; "featureType", `String feature;
        "views", `List [`Assoc ["uuid", `String (owner ^ ":default"); "name", `String "All";
          "type", `String "list"; "rows", `List []; "columns", `List []; "error", `String message]]]

let query_expansion_key session uuid =
  Option.fold ~none:"" ~some:(fun (config : Api.api_config) -> config.graph_id) (state session).config
  ^ "/" ^ uuid

let query_projection session db uuid =
  if not (Query_block.is_query db uuid) then None
  else if Outliner.Sset.mem (query_expansion_key session uuid) (state session).expanded_queries then
    Option.map (function `Assoc fields -> `Assoc (("expanded", `Bool true) :: fields) | value -> value)
      (query_for session db uuid)
  else Some (`Assoc ["kind", `String "deferred"; "ownerUuid", `String uuid;
    "featureType", `String "query-result"; "expanded", `Bool false;
    "rows", `List []; "views", `List []; "error", `Null])

let with_queries session result =
  match query_db session with
  | None -> result
  | Some db ->
    let cache = Hashtbl.create 8 in
    let presentation = Node_presentation.decorate db in
    let query uuid = match Hashtbl.find_opt cache uuid with
      | Some value -> value
      | None -> let value = query_projection session db uuid in
        Hashtbl.replace cache uuid value; value in
    let rec decorate = function
      | `List values -> `List (List.map decorate values)
      | `Assoc fields ->
        let fields = List.map (fun (key, value) ->
          key, if key = "query" then value else decorate value) fields in
        (match List.assoc_opt "uuid" fields, List.assoc_opt "pageId" fields,
           List.assoc_opt "isShell" fields with
         | Some (`String uuid), Some _, shell when shell <> Some (`Bool true) ->
           presentation uuid (match query uuid with
            | Some value -> `Assoc (("query", value) :: List.remove_assoc "query" fields)
            | None -> `Assoc fields)
         | _ -> `Assoc fields)
      | value -> value in
    decorate result

let success session result =
  Rpc.success (Rpc.with_node_icons (node_icon session) (with_queries session result))

let take count values =
  let rec loop count result = function
    | _ when count <= 0 -> List.rev result
    | [] -> List.rev result
    | value :: rest -> loop (count - 1) (value :: result) rest
  in loop count [] values

let projection_blocks session blocks =
  match (host session).Types.outliner_projection_limit with
  | None -> blocks | Some limit -> take limit blocks

let window_serializer session serialize blocks =
  match (host session).Types.outliner_projection_limit with
  | None -> serialize
  | Some limit ->
    let content = Hashtbl.create limit in
    List.iter (fun (block : Model.block) -> Hashtbl.replace content block.uuid ()) (take limit blocks);
    fun (block : Model.block) ->
      if Hashtbl.mem content block.uuid then serialize block else Rpc.block_shell_json block

let route_breadcrumbs context (route : Types.node_route) =
  if not route.zoom_to_block then []
  else
    let by_uuid = Hashtbl.create (List.length context.Outliner.blocks) in
    List.iter (fun (block : Model.block) -> Hashtbl.replace by_uuid block.uuid block) context.Outliner.blocks;
    let seen = Hashtbl.create 8 in
    let rec walk uuid ancestors =
      if uuid = route.page.uuid then route.page :: ancestors
      else if Hashtbl.mem seen uuid then ancestors
      else begin
        Hashtbl.add seen uuid ();
        match Hashtbl.find_opt by_uuid uuid with
        | None -> route.page :: ancestors
        | Some block ->
          let ancestors = if uuid = route.uuid then ancestors else
            ({ Model.uuid = block.uuid; title = block.title } : Model.entity_summary) :: ancestors in
          match block.parent_id with
          | Some parent -> walk parent ancestors
          | None -> route.page :: ancestors
      end
    in walk route.uuid []

let node_properties_for session uuid =
  match query_db session with
  | None -> `Null
  | Some db -> (match Node_property.render db ~owner:uuid ~encode_block:(result_block_encoder db) with
      | Ok value -> value | Error _ -> `Null)

let node_routes_json session serialize serialize_plain =
  let active = active_node_route session in
  Rpc.json_list
    (List.map
       (fun (route : Types.node_route) ->
         let current =
           match active with
           | Some active when active.uuid = route.uuid ->
             (state session).outliner_state
           | _ -> route.state
         in
         let context = node_route_context session route in
         let ordered = List.map (fun (row : Outliner.outliner_row) -> row.block)
           (Outliner.visible_rows context current) in
         let serialize = window_serializer session serialize ordered in
         let related = node_route_related_blocks session route in
         let linked = node_route_linked_reference_blocks session route in
         let serialize_related = window_serializer session serialize_plain related in
         let serialize_linked = window_serializer session serialize_plain linked in
         Rpc.json_object
           [
             ("uuid", `String route.uuid)
           ; ("breadcrumbs", Rpc.json_list (List.map (summary_json session) (route_breadcrumbs context route)))
           ; ("scrollTarget", match route.scroll_target with Some uuid -> `String uuid | None -> `Null)
           ; ("isTag", `Bool route.is_tag)
           ; ("isProperty", `Bool route.is_property)
           ; ("resultViews", object_views_for session route.uuid route.is_tag route.is_property)
           ; ("nodeProperties", node_properties_for session route.uuid)
           ; ("page", summary_json session route.page)
           ; ( "blocks"
             , Rpc.json_list (List.map serialize (projection_blocks session
                  (if (host session).Types.outliner_projection_limit = None then context.Outliner.blocks else ordered)))
             )
           ; ( "relatedBlocks"
             , Rpc.json_list
                 (List.map serialize_related related) )
           ; ( "linkedReferenceBlocks"
             , Rpc.json_list
                 (List.map serialize_linked linked) )
           ; ("outlinerState", Rpc.outliner_state_json current)
           ; ( "outlinerRows"
             , Rpc.outliner_rows_json serialize context current )
           ; ( "outlinerAutocompleteCandidates"
             , Rpc.outliner_candidates_json context current )
           ])
       (state session).node_routes)

let empty_journals_json session =
  let pages = match (host session).Types.empty_journals with
    | Some read -> read () | None -> [] in
  `List (List.map (fun ((page : Model.entity_summary), day) ->
    `Assoc ["uuid", `String page.uuid; "title", `String page.title;
      "journalDay", `Int day]) pages)

let snapshot session context_blocks blocks =
  let s = state session in
  let h = host session in
  let sidebar = sidebar_pages session in
  let current =
    match s.node_base_state with
    | Some base -> base
    | None -> s.outliner_state
  in
  let context =
    base_outliner_context_with_blocks session (Some sidebar) context_blocks
  in
  let serialized = Hashtbl.create 256 in
  let serialize (block : Model.block) =
    match Hashtbl.find_opt serialized block.uuid with
    | Some value -> value
    | None ->
      let value = Rpc.visible_block_json block in
      Hashtbl.replace serialized block.uuid value;
      value
  in
  let serialized_plain = Hashtbl.create 256 in
  let serialize_plain (block : Model.block) =
    match Hashtbl.find_opt serialized_plain block.uuid with
    | Some value -> value
    | None ->
      let value = Rpc.block_json block in
      Hashtbl.replace serialized_plain block.uuid value;
      value
  in
  let ordered = List.map (fun (row : Outliner.outliner_row) -> row.block)
    (Outliner.visible_rows context current) in
  let base_serialize = window_serializer session serialize ordered in
  let related = snapshot_related_blocks session in
  let linked = snapshot_linked_reference_blocks session in
  let related_serialize = window_serializer session Rpc.block_json related in
  let linked_serialize = window_serializer session Rpc.block_json linked in
  let config = s.config in
  let response =
    success session
      (Rpc.json_object
         [
           ("revision", `Int s.model.revision)
         ; ("pendingReferenceUuid", match So.pending_reference_uuid session with
             | Some uuid -> `String uuid | None -> `Null)
         ; ("blocks", Rpc.json_list (List.map base_serialize
             (if h.Types.outliner_projection_limit = None then blocks else projection_blocks session ordered)))
         ; ( "selectedBlock"
           , match Model.selected_block s.model with
             | Some block -> Rpc.block_json block
             | None -> `Null )
         ; ( "relatedBlocks"
           , Rpc.json_list
               (List.map related_serialize related)
           )
         ; ( "linkedReferenceBlocks"
           , Rpc.json_list
               (List.map linked_serialize linked) )
         ; ("resultViews", (match s.selected_sidebar_page with
             | Some page -> object_views_for session page.uuid (selected_page_is_tag session) (selected_page_is_property session)
             | None -> `Null))
         ; ("selectedPageIsTag", `Bool (selected_page_is_tag session))
         ; ("nodeProperties", (match s.selected_sidebar_page with
             | Some page -> node_properties_for session page.uuid | None -> `Null))
         ; ( "selectedPageIsProperty"
           , `Bool (selected_page_is_property session) )
         ; ("searchQuery", `String s.search_query)
         ; ("searchHasMore", `Bool s.search_has_more)
         ; ( "searchResults"
           , Rpc.json_list (List.concat_map (List.map Rpc.search_hit_json) (List.rev s.search_result_pages))
           )
         ; ( "flashcards"
           , Rpc.json_list (List.map Rpc.flashcard_json s.flashcards) )
         ; ("nodeRoutes", node_routes_json session serialize serialize_plain)
         ; ( "lastRefreshAt"
           , match s.model.last_refresh_at with
             | Some value -> `Int value
             | None -> `Null )
         ; ( "graphName"
           , match config with
             | Some config ->
               (match config.Api.graph_name with
                | Some name -> `String name
                | None -> `Null)
             | None -> `Null )
         ; ("journalTitleFormat", `String (Option.fold ~none:Journal.default_format ~some:Journal.format (query_db session)))
       ; ( "selectedGraphId"
           , match config with
             | Some config ->
               if config.Api.graph_id = "" then `Null
               else `String config.graph_id
             | None -> `Null )
         ; ( "graphs"
           , Rpc.json_list (List.map Rpc.graph_json s.available_graphs) )
         ; ( "favorites"
           , Rpc.json_list
               (List.map (summary_json session) sidebar.Graph_read.favorites) )
         ; ( "recentPages"
           , Rpc.json_list
               (List.map (summary_json session) sidebar.Graph_read.recent_pages)
           )
         ; ( "selectedPage"
           , match s.selected_sidebar_page with
             | Some page -> summary_json session page
             | None -> `Null )
         ; ( "isGraphEncrypted"
           , `Bool (selected_graph_is_encrypted session) )
         ; ( "isGraphUnlocked"
           , `Bool (selected_graph_is_unlocked session) )
         ; ( "appliedServerT"
           , match projection_server_t session with
             | Some value -> `Int value
             | None -> `Null )
         ; ("syncConnected", `Bool s.sync_connected)
         ; ("syncTransport", Sync_driver.to_yojson s.sync_transport)
         ; ( "taskPriorities"
           , Rpc.json_list (List.map Rpc.status_response_json
               (match query_db session with
                | Some db -> Graph_read.property_choices (fun text -> Ok text) db "logseq.property/priority"
                | None -> [])))
         ; ( "taskStatuses"
           , Rpc.json_list
               (List.map Rpc.status_response_json
                  (Model.all_statuses s.model)) )
         ; ("pendingSyncError", match Pump.pending_sync_error session with Some message -> `String message | None -> `Null)
         ; ("pendingSyncRequest", pending_request_json session)
         ; ("outlinerState", Rpc.outliner_state_json current)
         ; ( "outlinerAutocompleteCandidates"
           , Rpc.outliner_candidates_json context current )
         ; ("outlinerRows", Rpc.outliner_rows_json base_serialize context current)
         ; ("outlinerCommandRevision", `Int s.outliner_revision)
         ; ( "outlinerCommands"
           , Rpc.json_list
               (List.map Rpc.outliner_command_json s.outliner_commands) )
         ; ( "hasPendingSemanticOperations"
           , `Bool (has_pending_operations session) )
         ; ("emptyJournals", empty_journals_json session)
         ; ( "hasOlderJournals"
           , `Bool
               (match h.Types.has_older_journals with
                | Some read -> read ()
                | None -> false) )
         ; ("isOutlinerPatch", `Bool false)
         ])
  in
  if s.flashcards <> [] then
    debug
      ("flashcards snapshot encoded bytes="
       ^ string_of_int (String.length response));
  response

let outliner_patch_result session context blocks deleted splices =
  let s = state session in
  let blocks =
    if blocks = [] && splices = [] then blocks
    else match query_db session with
      | None -> blocks
      | Some db ->
        let queries = Hashtbl.create 8 and included = Hashtbl.create (List.length blocks) in
        List.iter (fun uuid -> Hashtbl.replace queries uuid ()) (Query_block.owner_uuids db);
        List.iter (fun (block : Model.block) -> Hashtbl.replace included block.uuid ()) blocks;
        let refreshed = List.filter (fun (block : Model.block) ->
          Hashtbl.mem queries block.uuid && not (Hashtbl.mem included block.uuid)) context.Outliner.blocks in
        List.rev_append (List.rev blocks) refreshed in
  let encoded = Rpc.outliner_patch_result s.model.revision context s.outliner_state
    ~node_icon:(node_icon session)
    ?sync_error:(Pump.pending_sync_error session)
    s.outliner_revision s.outliner_commands
    (has_pending_operations session)
    blocks deleted splices in
  match Json.from_string encoded with
  | `Assoc fields -> (match List.assoc_opt "result" fields with
      | Some (`Assoc result) -> success session (`Assoc (("emptyJournals", empty_journals_json session) :: result))
      | Some result -> success session result | None -> encoded)
  | _ -> encoded

let outliner_patch session context changed_ids =
  let changed =
    List.filter
      (fun block -> List.mem block.Model.uuid changed_ids)
      context.Outliner.blocks
  in
  outliner_patch_result session context changed [] []

let structural_outliner_patch anchored session before_context before_state
    after_context =
  let blocks, deleted, splices =
    Rpc.structural_outliner_delta anchored before_context before_state
      after_context (state session).outliner_state
  in
  outliner_patch_result session after_context blocks deleted splices

let snapshot_visible session =
  let s = state session in
  let h = host session in
  let context_blocks =
    match (s.selected_sidebar_page, h.Types.graph_page_blocks) with
    | Some node, Some load ->
      let page, _ = So.sidebar_node_destination session node in
      (match load page.Model.uuid with
       | Some blocks -> blocks
       | None -> [])
    | _ ->
      (match h.graph_blocks with
       | Some load ->
         let blocks =
           match load () with Some blocks -> blocks | None -> []
         in
         let local = Model.all_blocks s.model in
         List.map
           (fun (block : Model.block) ->
             match
               List.find_opt
                 (fun (local : Model.block) -> local.uuid = block.uuid)
                 local
             with
             | Some local ->
               (match local.local_path with
                | Some _ ->
                  { block with Model.local_path = local.local_path }
                | None -> block)
             | None -> block)
           blocks
       | None -> Model.visible_blocks s.model)
  in
  if s.flashcards <> [] then
    debug
      ("flashcards visible blocks loaded count="
       ^ string_of_int (List.length context_blocks));
  let blocks =
    if
      h.graph_blocks <> None || s.selected_sidebar_page <> None
    then context_blocks
    else Model.visible_from s.model context_blocks
  in
  snapshot session context_blocks blocks

let sidebar_snapshot session =
  session.Types.state :=
    { !(session.Types.state) with Types.sidebar_deferred = false };
  snapshot_visible session

let graph_catalog_snapshot session =
  let s = state session in
  success session
    (Rpc.json_object
       [
         ( "graphName"
         , match s.config with
           | Some config ->
             (match config.Api.graph_name with
              | Some name -> `String name
              | None -> `Null)
           | None -> `Null )
       ; ("journalTitleFormat", `String (Option.fold ~none:Journal.default_format ~some:Journal.format (query_db session)))
       ; ( "selectedGraphId"
         , match s.config with
           | Some config ->
             if config.Api.graph_id = "" then `Null
             else `String config.graph_id
           | None -> `Null )
       ; ( "graphs"
         , Rpc.json_list (List.map Rpc.graph_json s.available_graphs) )
       ; ("isGraphEncrypted", `Bool (selected_graph_is_encrypted session))
       ; ("isGraphUnlocked", `Bool (selected_graph_is_unlocked session))
       ; ("isGraphCatalogPatch", `Bool true)
       ])

let pending_sync_patch session =
  success session
    (Rpc.json_object
       [
         ("revision", `Int (state session).model.revision)
       ; ("blocks", Rpc.json_list [])
       ; ("selectedBlock", `Null)
       ; ( "appliedServerT"
         , match projection_server_t session with
           | Some value -> `Int value
           | None -> `Null )
       ; ("pendingSyncError", match Pump.pending_sync_error session with Some message -> `String message | None -> `Null)
       ; ("pendingSyncRequest", pending_request_json session)
       ; ( "hasPendingSemanticOperations"
         , `Bool (has_pending_operations session) )
       ; ("isPendingSyncPatch", `Bool true)
       ])

let reconcile_authoritative_blocks session =
  match (host session).Types.authoritative_graph_blocks with
  | Some load ->
    (match load () with
     | Some blocks ->
       Rpc.reconcile_authoritative_blocks (state session).model blocks
     | None -> ())
  | None -> ()

let discover_graphs session (config : Api.api_config) =
  debug "graph discovery started";
  match (host session).send (Api.graphs_request config) with
  | Error message -> Error message
  | Ok response ->
    if response.status < 200 || response.status >= 300 then begin
      debug
        (Printf.sprintf "graph discovery failed status=%d body=%S"
           response.status response.body);
      Error
        ("Logseq graphs API returned HTTP " ^ string_of_int response.status)
    end
    else
      (try
         session.Types.state :=
           {
             !(session.state) with
             available_graphs =
               Api.graphs_from_graphs_body response.body;
           };
         (match (host session).save_graph_catalog with
          | Some save -> save response.body
          | None -> ());
         Ok ()
       with error ->
         Error
           ("Could not parse Logseq graphs response: "
            ^ Printexc.to_string error))

let resolve_graph (config : Api.api_config) =
  if not (String_kit.is_blank config.graph_id) then begin
    debug ("graph discovery skipped graph=" ^ config.graph_id);
    Ok config
  end
  else Error "Select a Logseq graph before syncing"

let outliner_action_context session context message =
  let current = (state session).outliner_state in
  let targets = Outliner.interaction_targets current |> Outliner.Sset.elements in
  let targets = match message with
    | Outliner.Tap_block uuid | Long_press_block uuid | Toggle_collapsed uuid | Zoom_in uuid -> uuid :: targets
    | Drop_blocks value -> value.target_uuid :: targets
    | Set_task_status value -> value.status_uuid :: targets
    | Set_task_priority value -> value.priority_uuid :: targets
    | _ -> targets in
  let missing = List.filter (fun uuid -> Outliner.find_block context uuid = None) targets in
  match missing, query_db session with
  | [], _ | _, None -> context, false
  | _, Some db ->
    let pages = Hashtbl.create 4 in
    let extra = List.fold_left (fun blocks uuid ->
      match Graph_read.node_destination (fun text -> Ok text) db uuid with
      | Some (page, _) when not (Hashtbl.mem pages page.Model.uuid) ->
        Hashtbl.add pages page.uuid ();
        let loaded = Graph_read.blocks_for_page (fun text -> Ok text) db page.uuid in
        let loaded = match Datascript.entid db "block/uuid" (Datascript.Uuid page.uuid) with
          | Some eid -> (match Graph_read.page_block (fun text -> Ok text) db eid with
              | Some block -> block :: loaded | None -> loaded)
          | None -> loaded in
        List.rev_append loaded blocks
      | _ -> blocks) [] missing in
    So.with_extra_blocks context extra, extra <> []

let dispatch_outliner_event session payload =
  match Rpc.outliner_message payload with
  | Error message -> Rpc.failure "invalid_outliner_event" message
  | Ok message ->
    if
      not
        (Rpc.outliner_structure_source_matches
           (state session).outliner_state payload)
    then outliner_patch session (outliner_context session) []
    else begin
      let display_context, aggregate =
        match aggregate_return_context session payload message with
        | Some (context, uuid) -> (context, Some uuid)
        | None -> (outliner_context session, None)
      in
      let context, external_results = outliner_action_context session display_context message in
      let previous = (state session).outliner_state in
      let next_state, commands =
        Outliner.update context previous message
      in
      let base_t =
        match projection_server_t session with
        | Some t -> t
        | None -> -1
      in
      match
        Effects.interpret base_t now_ms fresh_squuid context commands
      with
      | Error error -> Rpc.failure "outliner_command_failed" error
      | Ok interpreted ->
        let operations =
          List.concat_map
            (fun operation -> normalize_operation_titles session operation)
            interpreted.Effects.operations
        in
        let enqueue_result =
          if operations = [] then Ok ()
          else if (state session).config = None then
            Error "Select a graph before editing"
          else if base_t = -1 then
            Error "A current server cursor is required"
          else
            List.fold_left
              (fun result operation ->
                let ( let* ) = Result.bind in
                let* () = result in
                enqueue_semantic session operation)
              (Ok ()) operations
        in
        (match enqueue_result with
         | Error error -> Rpc.failure "outliner_effect_failed" error
         | Ok () ->
           let page_scoped =
             aggregate <> None
             || (operations <> []
                 && (state session).selected_sidebar_page <> None)
           in
           let projected =
             if operations = [] then context
             else project_outliner_operations context operations
           in
           let projected =
             refresh_reference_metadata session aggregate projected
               operations
           in
           let next_state =
             List.fold_left
               (fun current (operation : Ops.pending_operation) ->
                 fst
                   (Outliner.update projected current
                      (Outliner.Operation_staged operation.intent)))
               next_state operations
           in
           let next_state = match message with
             | Outliner.Paste_content _ ->
               List.fold_left (fun current -> function
                 | Effects.Focus_block uuid ->
                   (match Outliner.find_block projected uuid with
                    | Some block -> fst (Outliner.staged_editing projected current uuid block.title false)
                    | None -> current)
                 | _ -> current) next_state interpreted.platform
             | _ -> next_state in
           session.Types.state :=
             {
               !(session.state) with
               outliner_state = next_state;
               outliner_optimistic_blocks = Some
                 (if not external_results then projected.Outliner.blocks
                  else
                    let pages = Hashtbl.create 4 in
                    List.iter (fun (block : Model.block) -> Hashtbl.replace pages block.page_id ())
                      display_context.Outliner.blocks;
                    List.filter (fun (block : Model.block) -> Hashtbl.mem pages block.page_id)
                      projected.blocks);
               outliner_commands = interpreted.platform;
               outliner_revision =
                 (state session).outliner_revision + 1;
             };
           (match message with
            | Outliner.Toggle_collapsed _ -> So.persist_collapsed_nodes session
            | _ -> ());
           if external_results || (state session).node_routes <> [] then
             snapshot_visible session
           else
             (match event_patch_plan message operations with
              | So.Patch_blocks changed ->
                outliner_patch session projected changed
              | So.Structural_diff ->
                if aggregate <> None && not page_scoped then
                  snapshot_visible session
                else
                  structural_outliner_patch page_scoped session context
                    previous projected))
    end

let switch_graph_model session payload =
  match (host session).Types.model_for_graph with
  | Some load ->
    (try
       match Json.from_string payload with
       | `Assoc fields ->
         (match
            List.assoc_opt "graphId" (Rpc.fields_of fields)
          with
          | Some (`String uuid) ->
            if uuid = "" then
              Error "graph storage payload requires graphId"
            else begin
              session.Types.state :=
                {
                  !(session.state) with
                  model = load uuid;
                  active_graph_id = Some uuid;
                  accepted_server_t = None;
                  pending_sync = None;
                  semantic_queue = [];
                  semantic_active = None;
                  flashcards = [];
                };
              clear_node_navigation session;
              session.state :=
                { !(session.state) with selected_sidebar_page = None };
              reset_outliner session;
              Ok ()
            end
          | _ -> Error "graph storage payload requires graphId")
       | _ -> Error "graph storage payload must be an object"
     with error -> Error (Printexc.to_string error))
  | None -> Ok ()

let with_object action payload missing handle =
  match payload with
  | Some payload ->
    (match
       try Ok (Json.from_string payload)
       with _ -> Error (action ^ " payload must be valid JSON")
     with
     | Error message -> Rpc.failure "invalid_json" message
     | Ok input ->
       (match input with
        | `Assoc fields -> handle input (Rpc.fields_of fields)
        | _ ->
          Rpc.failure "invalid_params"
            (action ^ " payload must be an object")))
  | None -> Rpc.failure "invalid_params" missing

let stage_result session operation_id base_t intent =
  match
    enqueue_semantic session
      {
        Ops.operation_id;
        base_t;
        state = Ops.Queued;
        intent;
      }
  with
  | Ok () -> snapshot_visible session
  | Error message -> Rpc.failure "stage_operation_failed" message

let editing_cursor session =
  match projection_server_t session with
  | None ->
    Error ("stale_server_cursor", "A current server cursor is required")
  | Some cursor ->
    if (state session).config = None then
      Error ("graph_not_configured", "Select a graph before editing")
    else Ok cursor

let checked_edit session operation_id expected verb missing build =
  match expected with
  | None -> Rpc.failure "invalid_params" missing
  | Some _ ->
    if (state session).config = None then
      Rpc.failure "graph_not_configured"
        ("Select a graph before "
         ^
         match verb with
         | "split" -> "splitting"
         | "merge" -> "merging"
         | "move" -> "moving"
         | _ -> "deleting")
    else
      (match projection_server_t session with
       | Some cursor ->
         if expected <> Some cursor then
           Rpc.failure "stale_server_cursor"
             ("The graph changed before " ^ verb)
         else
           (match build () with
            | Error message -> Rpc.failure "invalid_params" message
            | Ok intent ->
              stage_result session operation_id cursor intent)
       | None ->
         Rpc.failure "stale_server_cursor"
           "A current server cursor is required")

let configure session _input fields =
  let field name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Some value
    | _ -> None
  in
  match (field "baseUrl", field "token") with
  | Some base_url, Some token ->
    Option.iter (fun configure -> configure token) session.Types.host.configure_identity;
    let uuid =
      match field "graphId" with Some id -> id | None -> ""
    in
    let name =
      match field "graphName" with
      | Some name when not (String_kit.is_blank name) ->
        Some (String.trim name)
      | _ ->
        (match
           List.find_opt
             (fun (graph : Api.api_graph) -> graph.id = uuid)
             (state session).available_graphs
         with
         | Some graph -> Some graph.name
         | None -> None)
    in
    let config =
      {
        Api.base_url;
        graph_id = uuid;
        graph_name = name;
        token;
      }
    in
    let changed = match (state session).config with
      | Some previous -> previous.Api.graph_id <> config.graph_id || previous.base_url <> config.base_url
      | None -> false in
    if changed then begin
      cancel_pending_sync session;
      session.state := { !(session.state) with semantic_queue = [] }
    end;
    session.Types.state :=
      {
        !(session.state) with
        accepted_server_t = None;
        config = Some config;
        sync_connected =
          (match (state session).config with
           | Some previous when previous.Api.graph_id = config.graph_id
               && previous.base_url = config.base_url -> (state session).sync_connected
           | _ -> false);
        sync_transport =
          (match (state session).config with
           | Some previous when previous.Api.graph_id = config.graph_id
               && previous.base_url = config.base_url -> (state session).sync_transport
           | _ -> Sync_driver.invalidate (state session).sync_transport);
      };
    So.restore_collapsed_nodes session;
    if
      List.exists
        (fun (graph : Api.api_graph) -> graph.id = uuid && graph.e2ee)
        (state session).available_graphs
    then
      (match (host session).load_cached_graph_key with
       | Some load -> ignore (load config)
       | None -> ());
    snapshot_visible session
  | _ ->
    Rpc.failure "invalid_params"
      "configure requires baseUrl and token strings"

let select_graph session payload =
  match ((state session).config, payload) with
  | Some config, Some uuid ->
    (match
       List.find_opt
         (fun (graph : Api.api_graph) -> graph.id = uuid)
         (state session).available_graphs
     with
     | Some graph ->
       if not graph.Api.ready then
         Rpc.failure "graph_not_ready"
           "The selected graph is not ready for sync"
       else begin
         let config =
           {
             config with
             Api.graph_id = graph.id;
             graph_name = Some graph.name;
           }
         in
         if (state session).config <> Some config then begin
           cancel_pending_sync session;
           session.state := { !(session.state) with semantic_queue = [];
             sync_transport = Sync_driver.invalidate (state session).sync_transport; sync_connected = false }
         end;
         clear_node_navigation session;
         session.Types.state :=
           {
             !(session.state) with
             selected_sidebar_page = None;
             accepted_server_t = None;
             config = Some config;
           };
         reset_outliner session;
         if graph.e2ee then
           (match (host session).load_cached_graph_key with
            | Some load -> ignore (load config)
            | None -> ());
         snapshot_visible session
       end
     | None ->
       Rpc.failure "unknown_graph" "The selected graph is not available")
  | _ -> Rpc.failure "invalid_params" "selectGraph requires a graph id"

let hydrate_outliner_rows session payload =
  try
    let ids = match Yojson.Basic.from_string (Option.value ~default:"[]" payload) with
      | `List values -> List.filter_map (function `String value -> Some value | _ -> None) values
      | _ -> [] in
    if List.length ids > 32 then Rpc.failure "invalid_params" "At most 32 rows may be hydrated"
    else
      let wanted = Hashtbl.create 32 and found = Hashtbl.create 32 in
      List.iter (fun id -> Hashtbl.replace wanted id ()) ids;
      let collect blocks = List.iter (fun (block : Model.block) ->
        if Hashtbl.mem wanted block.uuid && not (Hashtbl.mem found block.uuid)
        then Hashtbl.add found block.uuid block) blocks in
      (* Reference projections carry ancestry that ordinary outline rows omit. *)
      collect (snapshot_related_blocks session);
      collect (snapshot_linked_reference_blocks session);
      List.iter (fun route ->
        if Hashtbl.length found < Hashtbl.length wanted then collect (node_route_related_blocks session route);
        if Hashtbl.length found < Hashtbl.length wanted then collect (node_route_linked_reference_blocks session route)) (state session).node_routes;
      if Hashtbl.length found < Hashtbl.length wanted then collect (outliner_context session).Outliner.blocks;
      if Hashtbl.length found < Hashtbl.length wanted then collect (base_outliner_context session).Outliner.blocks;
      List.iter (fun route ->
        if Hashtbl.length found < Hashtbl.length wanted then collect (node_route_context session route).Outliner.blocks) (state session).node_routes;
      success session (Rpc.json_object ["isOutlinerContentPatch", `Bool true;
        "selectedGraphId", (match (state session).config with Some config -> `String config.Api.graph_id | None -> `Null);
        "hydratedBlocks", Rpc.json_list (List.filter_map (fun id ->
          Option.map Rpc.visible_block_json (Hashtbl.find_opt found id)) ids)])
  with Yojson.Json_error message -> Rpc.failure "invalid_params" message

let asset_cache_path session uuid asset_type =
  (host session).resolve_asset_path
    (Filename.concat "Assets"
      (Api.url_encode uuid ^ "." ^ Api.url_encode (Api.normalize_asset_type asset_type)))

let cached_image_gallery session uuid =
  let blocks = (outliner_context session).Outliner.blocks in
  match (List.find_opt (fun (block : Model.block) -> block.uuid = uuid) blocks,
         (state session).config) with
  | Some selected, Some config ->
    let images = List.filter_map (fun (block : Model.block) ->
      let kind = Api.normalize_asset_type (Option.value ~default:"" block.asset_type) in
      if not block.is_asset || block.parent_id <> selected.parent_id
         || not (List.mem kind ["png"; "jpg"; "jpeg"; "gif"; "webp"; "heic"]) then None
      else
        let cached = asset_cache_path session block.uuid kind in
        let local_path = match block.local_path with
          | Some _ as path -> path
          | None -> Option.bind (Model.read_block (state session).model block.uuid)
              (fun (local : Model.block) -> local.local_path) in
        let local = Option.map (host session).resolve_asset_path local_path in
        let path = match local with Some path when Sys.file_exists path -> path | _ -> cached in
        if Sys.file_exists path then Some (block, path) else None) blocks
      |> List.sort (fun (a, _) (b, _) -> compare (a.Model.order, a.uuid) (b.Model.order, b.uuid)) in
    let index = ref (-1) in
    let paths = List.mapi (fun position (block, path) ->
      if block.Model.uuid = uuid then index := position;
      `String path) images in
    if !index < 0 then Rpc.failure "asset_unavailable" "The image is not cached"
    else success session (Rpc.json_object ["paths", Rpc.json_list paths; "selectedIndex", `Int !index])
  | _ -> Rpc.failure "asset_unavailable" "The image is not in the active page"

let graph_asset session fields downloaded =
  let ( let* ) = Result.bind in
  let result =
    let* uuid = Rpc.required_string fields "uuid" in
    let* asset_type = Rpc.required_string fields "assetType" in
    let graph_id = match List.assoc_opt "graphId" fields with
      | Some (`String id) -> id
      | _ -> Option.fold ~none:"" ~some:(fun config -> config.Api.graph_id) (state session).config in
    match (state session).config with
    | Some config when config.Api.graph_id = graph_id ->
      let kind = Api.normalize_asset_type asset_type in
      let path = asset_cache_path session uuid kind in
      let response () = Rpc.json_object ["graphId", `String graph_id; "localPath", `String path] in
      if Sys.file_exists path then Ok (response ())
      else if not downloaded then
        let request = Api.request config "GET"
          ("/assets/" ^ Api.url_encode graph_id ^ "/" ^ Api.url_encode uuid ^ "." ^ Api.url_encode kind) None in
        Ok (Rpc.json_object ["graphId", `String graph_id; "request", Rpc.request_json 0 request None "application/octet-stream" []])
      else
        let* source = Rpc.required_string fields "path" in
        let* bytes = Asset_files.read_file source in
        let* contents = if selected_graph_is_encrypted session then
          match (host session).decrypt_asset with
          | Some decrypt -> decrypt graph_id bytes
          | None -> Error "Asset decryption is unavailable"
          else Ok bytes in
        let* () = Asset_files.cache_download path contents in
        Ok (response ())
    | _ -> Error "graph_changed"
  in
  match result with
  | Ok value -> success session value
  | Error "graph_changed" -> Rpc.failure "graph_changed" "The active graph changed during asset download"
  | Error message -> Rpc.failure "asset_download_failed" message

let ensure_journal session payload =
  let day = Option.bind payload int_of_string_opt in
  match day with
  | None -> Rpc.failure "invalid_params" "A journal date is required"
  | Some day when not (Journal.valid_day day) -> Rpc.failure "invalid_params" "The journal date is invalid"
  | Some day ->
    let existing = Option.bind (host session).Types.journal_page_id (fun find -> find day) in
    let result = match existing, projection_server_t session, (state session).config with
      | Some uuid, _, _ -> Ok uuid
      | None, Some base_t, Some _ ->
        let uuid = Rpc.journal_page_uuid day in
        let operation = { Ops.operation_id = fresh_squuid ();
          base_t; state = Ops.Queued;
          intent = Ops.Create_journal { Ops.page_uuid = uuid; block_uuid = fresh_squuid (); block_title = "";
            title = (match query_db session with Some db -> Journal.title db day | None -> Rpc.journal_day_title day); journal_day = day; created_at = now_ms () } } in
        Result.map (fun () -> uuid) (enqueue_semantic session operation)
      | None, _, _ -> Error "Select a graph before creating a journal"
    in
    match result with
    | Ok uuid -> success session (Rpc.json_object ["uuid", `String uuid])
    | Error message -> Rpc.failure "journal_creation_failed" message

let set_journal_title_format session fields =
  let result =
    let ( let* ) = Result.bind in
    let* graph_id = Rpc.required_string fields "graphId" in
    let* format = Rpc.required_string fields "format" in
    let* () = match (state session).config with
      | Some config when config.Api.graph_id = graph_id -> Ok ()
      | _ -> Error "The active graph changed. Reopen settings to change its date format" in
    let* () = if List.mem format Journal.built_in_journal_title_formatters then Ok ()
      else Error "Choose a supported date format" in
    let* db = Option.to_result ~none:"The graph is unavailable" (query_db session) in
    let* eid = Option.to_result ~none:"The Journal class is missing"
      (Datascript.entid db "db/ident" (Datascript.Keyword "logseq.class/Journal")) in
    let* uuid = Option.to_result ~none:"The Journal class has no UUID" (Graph_read.uuid_for_eid db eid) in
    let* base_t = match editing_cursor session with Ok value -> Ok value | Error (_, message) -> Error message in
    let* expected = match Graph_read.value db eid Journal.format_attr with
      | None -> Ok None
      | Some (Datascript.String value) -> Ok (Some (Ops.String_value value))
      | _ -> Error "The existing journal format is invalid" in
    let value = Some (Ops.String_value format) in
    if expected = value then Ok () else
    enqueue_semantic session {Ops.operation_id = fresh_squuid (); base_t; state = Ops.Queued;
      intent = Ops.Set_property {uuid; attr = Journal.format_attr; expected; value}}
  in
  match result with
  | Ok () -> snapshot_visible session
  | Error message -> Rpc.failure "date_format_failed" message

let select_page session payload =
  match
    ( payload
    , match (host session).Types.graph_sidebar_pages with
      | Some load -> load ()
      | None -> None )
  with
  | Some uuid, Some pages ->
    (match
       List.find_opt
         (fun (page : Model.entity_summary) -> page.uuid = uuid)
         (pages.Graph_read.favorites @ pages.recent_pages)
     with
     | Some page ->
       clear_node_navigation session;
       session.Types.state :=
         { !(session.state) with selected_sidebar_page = Some page };
       session.state :=
         {
           !(session.state) with
           related_blocks =
             (if selected_page_is_tag session then []
              else
                So.references_for_node session page.Model.uuid);
         };
       reset_outliner session;
       let _, zoom = So.sidebar_node_destination session page in
       if zoom then begin
         let outliner_state, _ = Outliner.update
           (So.base_outliner_context_live session) (state session).outliner_state
           (Outliner.Zoom_in page.uuid) in
         session.state := { !(session.state) with outliner_state }
       end;
       snapshot_visible session
     | None ->
       Rpc.failure "unknown_page" "The selected page is not available")
  | _ -> Rpc.failure "invalid_params" "selectPage requires a page id"

let open_node session fields =
  match Rpc.required_string fields "uuid" with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok uuid ->
    (match
       (match (host session).Types.graph_node_destination with
        | Some resolve -> resolve uuid
        | None -> None)
       |> function
       | Some result -> Some result
       | None -> projected_node_destination session uuid
     with
     | Some (page, zoom) ->
       let reveal = zoom && List.assoc_opt "reveal" fields = Some (`Bool true) in
       let scroll_target = if reveal then Some uuid else None in
       let uuid = if reveal then page.uuid else uuid in
       let tag =
         match (host session).graph_node_is_tag with
         | Some check -> check uuid
         | None -> false
       in
       let property =
         match (host session).graph_node_is_property with
         | Some check -> check uuid
         | None -> false
       in
       let related =
         if tag then
           match (host session).graph_tag_objects with
           | Some load -> Option.value ~default:[] (load uuid)
           | None -> []
         else So.references_for_node session uuid
       in
       let route =
         {
           Types.uuid;
           is_tag = tag;
           is_property = property;
           page;
           scroll_target;
           zoom_to_block = zoom && not reveal;
           related_blocks = related;
           state = Outliner.empty;
         }
       in
       push_node_route session route;
       snapshot_visible session
     | None ->
       Rpc.failure "unknown_node" "The referenced node is not available")

let send_message session payload =
  match Rpc.send_payload payload with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok (text, uuid, now) ->
    if text = "" then snapshot_visible session
    else begin
      let now = match now with Some now -> now | None -> now_ms () in
      let uuid =
        match uuid with
        | Some uuid -> uuid
        | None -> "local-" ^ string_of_int now
      in
      let h = host session in
      if
        (state session).config <> None
        && h.Types.stage_operation <> None
        && h.prepare_operation <> None
      then
        match enqueue_capture session uuid text now None with
        | Ok () -> snapshot_visible session
        | Error message -> Rpc.failure "capture_failed" message
      else begin
        Model.cache_local_message (state session).model uuid text now;
        snapshot_visible session
      end
    end

let prepare_capture_tags session uuid tags (operation : Ops.pending_operation) now =
  let ( let* ) = Result.bind in
  let* db = match query_db session with Some db -> Ok db | None -> Error "The graph is unavailable" in
  let* tx = Pending_projection.compile db operation.intent in
  try
    let db = Datascript.db_with tx db in
    let field name = match tags with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields)
      | _ -> invalid_arg "Invalid tags" in
    let strings name = match field name with
      | `Null -> []
      | `List values -> List.map (function `String value -> value | _ -> invalid_arg "Choose a tag") values
      | _ -> invalid_arg "Invalid tag selection" in
    let catalog = Hashtbl.create 32 in
    Graph_read.tag_pages (fun value -> Ok value) db |> List.iter (fun (tag : Model.entity_summary) ->
      let key = Dev_query.Unicode.lowercase tag.title in
      let previous = Option.value ~default:[] (Hashtbl.find_opt catalog key) in
      Hashtbl.replace catalog key (tag.uuid :: previous));
    let selected = ref (strings "selectedValues") and created = ref [] in
    let seen = Hashtbl.create 8 in
    List.iter (fun title ->
      let title = String.trim title in
      if title = "" then invalid_arg "Enter a tag name";
      let key = Dev_query.Unicode.lowercase title in
      if not (Hashtbl.mem seen key) then (
        Hashtbl.add seen key ();
        match Hashtbl.find_opt catalog key with
        | Some [uuid] -> selected := uuid :: !selected
        | Some _ -> invalid_arg "More than one tag has this name; choose the existing tag"
        | None -> created := title :: !created)) (strings "newValues");
    let property = Result_view.property_json ~include_candidates:false db ~owner:uuid ~attr:"block/tags" ~encode_block:(fun _ -> `Null) in
    let expected = match property with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt "raw" fields) | _ -> `Null in
    let id = match Datascript.entid db "block/uuid" (Datascript.Uuid uuid) with Some id -> id | None -> invalid_arg "Missing capture" in
    let existing = Graph_read.entity_summaries (fun value -> Ok value) db id "block/tags"
      |> List.map (fun (tag : Model.entity_summary) -> tag.uuid) in
    let selected = List.sort_uniq String.compare (existing @ !selected) in
    let intent = Result_view.edit_property ~allow_builtin:true db ~now ~fresh_uuid:fresh_squuid
      (`Assoc ["blockUuid", `String uuid; "attr", `String "block/tags"; "expected", expected;
        "value", `String ""; "create", `Bool true;
        "selectedValues", `List (List.map (fun uuid -> `String uuid) selected);
        "newValues", `List (List.map (fun title -> `String title) (List.rev !created))]) in
    let* _ = Pending_projection.compile db intent in
    Ok intent
  with Invalid_argument message | Failure message -> Error message

let send_tagged session input fields =
  let ( let* ) = Result.bind in
  let prepared =
    let* text = Rpc.required_string fields "text" in
    let* uuid = Rpc.required_string fields "uuid" in
    let* now = Rpc.optional_int fields "now" in
    let* status = Rpc.optional_status_payload input in
    let now = Option.value ~default:(now_ms ()) now in
    let text = String.trim text in
    if text = "" then Error "Enter text to capture" else
    let* operations = capture_operations session uuid text now status in
    match operations with
    | [] -> Error "The capture is unavailable"
    | first :: _ ->
      let operation = {first with Ops.operation_id = fresh_squuid ();
        intent = Ops.Atomic (List.map (fun (op : Ops.pending_operation) -> op.intent) operations)} in
      let tags = match input with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt "tags" fields) | _ -> `Null in
      let* tag_intent = prepare_capture_tags session uuid tags operation now in
      Ok {operation with Ops.intent = Ops.Atomic [operation.intent; tag_intent]}
  in
  match prepared with
  | Error message -> Rpc.failure "capture_failed" message
  | Ok operation -> (match enqueue_semantic session operation with
      | Ok () -> snapshot_visible session
      | Error message -> Rpc.failure "capture_failed" message)

let composer_tags session =
  let tags = match (host session).Types.graph_tag_pages with
    | Some load -> Option.value ~default:[] (load ())
    | None -> Option.fold ~none:[] ~some:(Graph_read.tag_pages (fun value -> Ok value)) (query_db session) in
  Rpc.success (`Assoc ["selectedGraphId", (match (state session).config with Some config -> `String config.graph_id | None -> `Null);
    "composerTagChoices", `List (List.map (fun (tag : Model.entity_summary) ->
      `Assoc ["uuid", `String tag.uuid; "title", `String tag.title]) tags)])

let send_task session input fields =
  match
    let ( let* ) = Result.bind in
    let* text = Rpc.required_string fields "text" in
    let* uuid = Rpc.required_string fields "uuid" in
    let* now = Rpc.optional_int fields "now" in
    let* status = Rpc.status_payload input in
    Ok (text, uuid, now, status)
  with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok (text, uuid, now, status) ->
    let text = String.trim text in
    if text = "" then snapshot_visible session
    else begin
      let now = match now with Some now -> now | None -> now_ms () in
      let h = host session in
      if
        (state session).config <> None
        && h.Types.stage_operation <> None
        && h.prepare_operation <> None
      then
        match enqueue_capture session uuid text now (Some status) with
        | Ok () -> snapshot_visible session
        | Error message -> Rpc.failure "capture_failed" message
      else begin
        Model.cache_local_task (state session).model uuid text status now;
        snapshot_visible session
      end
    end

let update_block_status session input fields =
  if (host session).Types.stage_operation <> None then
    match
      let ( let* ) = Result.bind in
      let* uuid = Rpc.required_string fields "uuid" in
      let* operation_id = Rpc.required_string fields "operationId" in
      let* expected_uuid =
        Rpc.optional_string fields "expectedStatusUuid"
      in
      let* expected_ident =
        Rpc.optional_string fields "expectedStatusIdent"
      in
      let* status = Rpc.status_payload input in
      Ok (uuid, operation_id, expected_uuid, expected_ident, status)
    with
    | Error message -> Rpc.failure "invalid_params" message
    | Ok (uuid, operation_id, expected_uuid, expected_ident, status) ->
      (match editing_cursor session with
       | Error (code, message) -> Rpc.failure code message
       | Ok cursor ->
         let expected =
           match expected_ident with
           | Some ident -> Some (Ops.Ref_ident ident)
           | None ->
             (match expected_uuid with
              | Some uuid -> Some (Ops.Ref_uuid uuid)
              | None -> None)
         in
         stage_result session operation_id cursor
           (Ops.Set_property
              {
                Ops.uuid;
                attr = "logseq.property/status";
                expected;
                value = Some (Rpc.status_semantic_ref status);
              }))
  else
    match
      let ( let* ) = Result.bind in
      let* uuid = Rpc.required_string fields "uuid" in
      let* status = Rpc.status_payload input in
      Ok (uuid, status)
    with
    | Error message -> Rpc.failure "invalid_params" message
    | Ok (uuid, status) ->
      (match
         Model.update_block_status (state session).model uuid status
           (now_ms ())
       with
       | Ok () -> snapshot_visible session
       | Error message -> Rpc.failure "unknown_block" message)

let update_block session input fields =
  if (host session).Types.stage_operation <> None then
    match
      let ( let* ) = Result.bind in
      let* uuid = Rpc.required_string fields "uuid" in
      let* operation_id = Rpc.required_string fields "operationId" in
      let* expected = Rpc.required_string fields "expectedTitle" in
      let* title = Rpc.required_string fields "title" in
      Ok (uuid, operation_id, expected, String.trim title)
    with
    | Error message -> Rpc.failure "invalid_params" message
    | Ok (uuid, operation_id, expected, title) ->
      (match editing_cursor session with
       | Error (code, message) -> Rpc.failure code message
       | Ok cursor ->
         if title = "" then
           Rpc.failure "invalid_params"
             "updateBlock title must not be empty"
         else
           stage_result session operation_id cursor
             (Ops.Save_title
                { Ops.uuid; expected_title = expected; title }))
  else
    match
      let ( let* ) = Result.bind in
      let* uuid = Rpc.required_string fields "uuid" in
      let* title = Rpc.required_string fields "title" in
      let* status = Rpc.optional_status_payload input in
      Ok (uuid, String.trim title, status)
    with
    | Error message -> Rpc.failure "invalid_params" message
    | Ok (uuid, title, status) ->
      if title = "" then
        Rpc.failure "invalid_params"
          "updateBlock title must not be empty"
      else
        (match
           Model.update_block_title (state session).model uuid title
             (now_ms ())
         with
         | Error message -> Rpc.failure "unknown_block" message
         | Ok () ->
           (match status with
            | Some status ->
              ignore
                (Model.update_block_status (state session).model uuid
                   status (now_ms ()))
            | None -> ());
           snapshot_visible session)

let split_block session fields =
  match
    let ( let* ) = Result.bind in
    let* uuid = Rpc.required_string fields "uuid" in
    let* operation_id = Rpc.required_string fields "operationId" in
    let* expected = Rpc.optional_int fields "expectedServerT" in
    let* title = Rpc.required_string fields "expectedTitle" in
    let* before = Rpc.required_string fields "before" in
    let* after = Rpc.required_string fields "after" in
    let* new_uuid = Rpc.required_string fields "newUuid" in
    let* order = Rpc.required_string fields "newOrder" in
    let* created = Rpc.optional_int fields "createdAt" in
    Ok
      ( operation_id
      , expected
      , created
      , {
          Ops.uuid;
          expected_title = title;
          before;
          after;
          new_uuid;
          new_order = order;
          created_at = (match created with Some c -> c | None -> 0);
        } )
  with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok (operation_id, expected, created, value) ->
    if created = None then
      Rpc.failure "invalid_params"
        "splitBlock requires integer cursor and timestamp"
    else
      checked_edit session operation_id expected "split"
        "splitBlock requires integer cursor and timestamp"
        (fun () ->
          if
            value.Ops.uuid = value.new_uuid
            || String_kit.is_blank value.new_uuid
            || String_kit.is_blank value.new_order
          then Error "Invalid split block fragments or identity"
          else Ok (Ops.Split_block value))

let merge_backward session fields =
  match
    let ( let* ) = Result.bind in
    let* uuid = Rpc.required_string fields "uuid" in
    let* operation_id = Rpc.required_string fields "operationId" in
    let* expected = Rpc.optional_int fields "expectedServerT" in
    let* expected_title = Rpc.required_string fields "expectedTitle" in
    let* title = Rpc.required_string fields "title" in
    let* previous = Rpc.required_string fields "previousUuid" in
    let* previous_title =
      Rpc.required_string fields "expectedPreviousTitle"
    in
    Ok
      ( operation_id
      , expected
      , {
          Ops.uuid;
          expected_title;
          title;
          previous_uuid = previous;
          expected_previous_title = previous_title;
          merged_title = None;
        } )
  with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok (operation_id, expected, value) ->
    checked_edit session operation_id expected "merge"
      "mergeBackward requires expectedServerT"
      (fun () ->
        if value.Ops.uuid = value.previous_uuid then
          Error "merge source and target must differ"
        else Ok (Ops.Merge_backward value))

let move_blocks session input fields =
  match
    let ( let* ) = Result.bind in
    let* operation_id = Rpc.required_string fields "operationId" in
    let* expected = Rpc.optional_int fields "expectedServerT" in
    let* moves = Rpc.required_moves input in
    Ok (operation_id, expected, moves)
  with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok (operation_id, expected, moves) ->
    checked_edit session operation_id expected "move"
      "moveBlocks requires expectedServerT"
      (fun () ->
        let uuids =
          List.sort_uniq compare
            (List.map (fun (move : Pending_ops.pending_move) -> move.uuid)
               moves)
        in
        if moves = [] || List.length moves <> List.length uuids then
          Error "moveBlocks requires distinct moves"
        else Ok (Ops.Move_blocks { Ops.moves }))

let delete_blocks session input fields =
  match
    let ( let* ) = Result.bind in
    let* operation_id = Rpc.required_string fields "operationId" in
    let* expected = Rpc.optional_int fields "expectedServerT" in
    let* uuids = Rpc.required_string_list "uuids" input in
    Ok (operation_id, expected, uuids)
  with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok (operation_id, expected, uuids) ->
    checked_edit session operation_id expected "delete"
      "deleteBlocks requires expectedServerT"
      (fun () ->
        if uuids = [] then Error "deleteBlocks requires block ids"
        else
          Ok
            (Ops.Delete_blocks
               { Ops.uuids = List.sort_uniq compare uuids }))

let delete_block session fields =
  match
    let ( let* ) = Result.bind in
    let* uuid = Rpc.required_string fields "uuid" in
    let* operation_id = Rpc.required_string fields "operationId" in
    let* expected = Rpc.optional_int fields "expectedServerT" in
    Ok (uuid, operation_id, expected)
  with
  | Error message -> Rpc.failure "invalid_params" message
  | Ok (uuid, operation_id, expected) ->
    checked_edit session operation_id expected "delete"
      "deleteBlock requires expectedServerT"
      (fun () ->
        Ok (Ops.Delete_blocks { Ops.uuids = [ uuid ] }))

let reload_flashcards session now =
  session.Types.state :=
    {
      !(session.state) with
      flashcards =
        (match (host session).graph_due_flashcards with
         | Some load -> load now
         | None -> []);
    }

let sync_transport_editing session =
  let s = state session in
  Outliner.editing_uuid s.outliner_state <> None
  || List.exists (fun (route : Types.node_route) -> Outliner.editing_uuid route.state <> None) s.node_routes

let publish_sync_transport session transport =
  session.Types.state := { (state session) with
    sync_transport = transport; sync_connected = Sync_driver.connected transport };
  snapshot_visible session

let begin_sync_transport session _input _fields =
  match (state session).config with
  | Some config when config.Api.graph_id <> "" ->
    (match Sync_driver.begin_connection config
       ~cursor:(projection_server_t session) ~editing:(sync_transport_editing session)
       (state session).sync_transport with
     | Ok transport -> publish_sync_transport session transport
     | Error message -> Rpc.failure "invalid_sync_transport" message)
  | _ -> Rpc.failure "graph_not_configured" "Select a graph before starting sync"

let sync_transport_event session _input fields =
  let field name = Option.value ~default:`Null (List.assoc_opt name fields) in
  let previous = (state session).sync_transport in
  let current_graph = match (state session).config with Some config -> config.Api.graph_id | None -> "" in
  if field "generation" <> `Int (Sync_driver.generation previous)
     || field "graphId" <> `String current_graph
     || current_graph <> Sync_driver.graph_id previous then
    publish_sync_transport session (Sync_driver.without_commands previous)
  else
    let message = match field "message" with `String value -> value | _ -> "Transport failed" in
    let event = match field "type" with
      | `String "opened" -> Some Sync_driver.Opened
      | `String "frame" -> (match field "body" with `String value -> Some (Sync_driver.Frame value) | _ -> None)
      | `String "failed" | `String "snapshot-failed" -> Some (Sync_driver.Failed message)
      | `String "closed" -> Some Sync_driver.Closed
      | `String "cancelled" -> Some Sync_driver.Cancelled
      | `String "snapshot-applied" -> Some Sync_driver.Snapshot_applied
      | `String "network" -> (match field "available" with `Bool value -> Some (Sync_driver.Network value) | _ -> None)
      | _ -> None in
    match event with
    | None -> Rpc.failure "invalid_sync_transport_event" "Sync event requires a supported type and payload"
    | Some event ->
      let apply_frame body = match (host session).Types.apply_sync_event with
        | None -> Error "Graph sync transport is unavailable"
        | Some apply ->
          (match apply body with
           | Error _ as error -> error
           | Ok () -> reconcile_authoritative_blocks session; Ok (projection_server_t session)) in
      let transport = Sync_driver.receive ~cursor:(projection_server_t session)
        ~editing:(sync_transport_editing session) ~apply_frame event previous in
      publish_sync_transport session transport

let child_context session parent_id =
  let current = outliner_context session in
  match (host session).Types.graph_node_destination with
  | Some resolve ->
    (match resolve parent_id with
     | Some (page, _) -> Option.value ~default:current (page_outliner_context session page.Model.uuid)
     | None -> current)
  | None -> current

let deep_link_response session extra =
  match Json.from_string (snapshot_visible session) with
  | `Assoc envelope ->
    let fields = match List.assoc_opt "result" envelope with Some (`Assoc fields) -> fields | _ -> [] in
    Json.to_string (`Assoc (("result", `Assoc (extra @ fields)) :: List.remove_assoc "result" envelope))
  | _ -> Rpc.failure "invalid_deep_link" "No application projection is available"

let graph_deep_link session graph page block =
  let current = state session in
  let graph = if graph = "" then Option.fold ~none:"" ~some:(fun (c : Api.api_config) -> c.graph_id) current.config else graph in
  let matches (candidate : Api.api_graph) = candidate.id = graph || candidate.name = graph in
  let candidates = List.filter matches current.available_graphs in
  let candidates = if candidates <> [] then candidates else
    List.filter (fun (candidate : Api.api_graph) ->
      Dev_query.Unicode.lowercase candidate.name = Dev_query.Unicode.lowercase graph) current.available_graphs in
  let target = match candidates with
    | [candidate] when candidate.Api.ready -> Ok candidate.id
    | [_] -> Error "The linked graph is not ready"
    | _ :: _ -> Error "More than one graph has this name; use its graph identifier"
    | [] -> (match current.config with
        | Some config when config.graph_id = graph || config.graph_name = Some graph -> Ok config.graph_id
        | _ -> Error "The linked graph is not available") in
  match target with
  | Error message -> Rpc.failure "invalid_deep_link" message
  | Ok target when Option.map (fun (config : Api.api_config) -> config.graph_id) current.config <> Some target ->
    deep_link_response session ["deepLinkGraphId", `String target]
  | Ok _ ->
    (match block, page with
     | None, None -> deep_link_response session ["deepLinkQuickAction", `String "journal"]
     | _ ->
       let target = Option.get (match block with Some _ -> block | None -> page) in
       let uuid = Option.bind (query_db session) (fun db ->
         let id = match block with
           | Some _ -> Datascript.entid db "block/uuid" (Datascript.Uuid target)
           | None -> (match Seq.uncons (Datascript.Db.datoms db Datascript.Avet
               ~a:"block/name" ~v:(Datascript.String (Dev_query.Unicode.lowercase target)) ()) with
               | Some (datom, _) -> Some datom.Datascript.e
               | None -> Datascript.entid db "block/uuid" (Datascript.Uuid target)) in
         Option.bind id (Graph_read.uuid_for_eid db)) in
       match uuid with
       | Some uuid -> deep_link_response session ["deepLinkNodeUuid", `String uuid]
       | None -> Rpc.failure "invalid_deep_link" "The linked page or block is not available")

let rec dispatch session action payload =
  let s = state session in
  let h = host session in
  let object_action handle =
    with_object action payload
      (action ^ " requires a JSON payload")
      handle
  in
  match action with
  | "completeAssetTranscription" -> object_action (fun _ fields ->
    match Rpc.required_string fields "parentId", Rpc.required_string fields "text" with
    | Ok parent_id, Ok text ->
      let text = String.trim text in
      let blocks = (child_context session parent_id).Outliner.blocks in
      if text = "" || List.exists (fun (block : Model.block) -> block.parent_id = Some parent_id && block.title = text) blocks
      then snapshot_visible session
      else dispatch session "addChildBlock" (Some (Json.to_string (`Assoc [
        "uuid", `String (fresh_squuid ()); "parentId", `String parent_id; "title", `String text])))
    | _, Error message | Error message, _ -> Rpc.failure "invalid_transcript" message)
  | "captureShared" -> object_action (fun _ fields ->
    match Rpc.required_string fields "uuid", Shared_capture.text fields with
    | Ok uuid, Ok text ->
      let existing = Model.read_block (state session).model uuid <> None
        || (match h.graph_node_destination with Some lookup -> lookup uuid <> None | None -> false) in
      if existing then snapshot_visible session else
        send_message session (Some (Json.to_string (`Assoc ["uuid", `String uuid; "text", `String text])))
    | _, Error message | Error message, _ -> Rpc.failure "invalid_shared_capture" message)
  | "handleDeepLink" -> object_action (fun _ fields ->
    match Shared_capture.deep_link fields with
    | Error message -> Rpc.failure "invalid_deep_link" message
    | Ok (`Capture text) -> dispatch session "captureShared" (Some (Json.to_string
        (`Assoc (("text", `String text) :: List.filter (fun (key, _) -> key <> "text" && key <> "title" && key <> "url") fields))))
    | Ok (`Graph (graph, page, block)) -> graph_deep_link session graph page block
    | Ok action ->
      let quick_action = match action with `Quick_action value -> `String value | _ -> `Null in
      let response = Json.from_string (snapshot_visible session) in
      (match response with
       | `Assoc envelope ->
         let result = match List.assoc_opt "result" envelope with Some (`Assoc fields) -> fields | _ -> [] in
         Json.to_string (`Assoc (("result", `Assoc (("deepLinkQuickAction", quick_action) :: result)) :: List.remove_assoc "result" envelope))
       | _ -> Rpc.failure "invalid_deep_link" "No application projection is available"))
  | "bootstrapGraph" -> object_action (fun input fields ->
    let requested = Rpc.required_string fields "graphId" in
    match requested, s.config with
    | Ok graph_id, Some config when graph_id = config.Api.graph_id ->
      let forced = Yojson.Basic.Util.member "forceSnapshot" input = `Bool true in
      let allowed = Yojson.Basic.Util.member "allowSnapshotDownload" input <> `Bool false in
      let respond kind =
        if kind = "download" then session.state := { !(session.state) with bootstrap_generation = (state session).bootstrap_generation + 1 };
        let has_token = match Yojson.Basic.Util.member "hasAccessToken" input with
          | `Bool value -> value | _ -> String.trim config.Api.token <> "" in
        let sync_allowed = has_token && selected_graph_is_unlocked session && kind <> "locked" in
        (* Interactive graph activation must finish the deferred sidebar load.
           Cold launch still uses openGraph and loads its sidebar afterward. *)
        let response = if kind = "ready" then sidebar_snapshot session else snapshot_visible session in
        let snapshot = Json.from_string response in
        match snapshot with
        | `Assoc envelope ->
          let result = match List.assoc_opt "result" envelope with Some (`Assoc fields) -> fields | _ -> [] in
          let plan = `Assoc ["kind", `String kind; "isEncrypted", `Bool (selected_graph_is_encrypted session);
            "syncAllowed", `Bool sync_allowed; "generation", `Int (state session).bootstrap_generation] in
          Json.to_string (`Assoc (("result", `Assoc (("graphBootstrap", plan) :: result)) :: List.remove_assoc "result" envelope))
        | _ -> Rpc.failure "invalid_bootstrap" "No graph projection is available" in
      if selected_graph_is_encrypted session && not (selected_graph_is_unlocked session) then respond "locked"
      else if not forced && s.active_graph_id = Some graph_id && projection_server_t session <> None then respond "ready"
      else
        let path = Rpc.required_string fields "activePath" and checkpoint = Rpc.required_string fields "checkpointPath" in
        (match path, checkpoint with
         | Ok active, Ok checkpoint ->
           let downloaded () = if allowed then respond "download"
             else Rpc.failure "snapshot_unavailable" "The graph is not cached and snapshot download is unavailable" in
           if not forced && Sys.file_exists active && Sys.file_exists checkpoint then
             let payload = Json.to_string (`Assoc (("isEncrypted", `Bool (selected_graph_is_encrypted session)) :: List.remove_assoc "isEncrypted" fields)) in
             let opened = dispatch session "openGraph" (Some payload) in
             if Yojson.Basic.Util.member "ok" (Json.from_string opened) = `Bool true then respond "ready" else downloaded ()
           else downloaded ()
         | _ -> Rpc.failure "invalid_params" "Graph storage paths are required")
    | _ -> Rpc.failure "graph_changed" "The requested graph is not selected")
  | "snapshotDownloadPlan" | "resolveSnapshotDownload" ->
    object_action (fun _ fields ->
      let result = if action = "snapshotDownloadPlan" then Snapshot_download.plan fields
        else Snapshot_download.resolve fields in
      match result with Ok value -> success session value | Error message -> Rpc.failure "invalid_snapshot_download" message)
  | "executeEffect" ->
    (match Core_effect.request ~now:now_ms ~fresh_id:fresh_squuid payload with
     | Ok (action, payload) -> dispatch session action payload
     | Error message -> Rpc.failure "invalid_effect" message)
  | "outlinerEvent" ->
    (match payload with
     | Some payload -> dispatch_outliner_event session payload
     | None ->
       Rpc.failure "invalid_params"
         "outlinerEvent requires a JSON payload")
  | "configure" -> object_action (configure session)
  | "beginSyncTransport" -> object_action (begin_sync_transport session)
  | "syncTransportEvent" -> object_action (sync_transport_event session)
  | "refresh" ->
    (match s.config with
     | Some config ->
       if String_kit.is_blank config.Api.graph_id then
         match discover_graphs session config with
         | Ok () -> snapshot_visible session
         | Error message ->
           Rpc.failure "graph_discovery_failed" message
       else if selected_graph_is_encrypted session then
         if selected_graph_is_unlocked session then
           snapshot_visible session
         else
           Rpc.failure "encrypted_graph_locked"
             "Unlock the encrypted graph first"
       else snapshot_visible session
     | None -> snapshot_visible session)
  | "refreshGraphCatalog" ->
    (match s.config with
     | Some config ->
       (match discover_graphs session config with
        | Ok () ->
          let name =
            match
              List.find_opt
                (fun (graph : Api.api_graph) ->
                  graph.id = config.Api.graph_id)
                (state session).available_graphs
            with
            | Some graph -> Some graph.name
            | None -> None
          in
          session.Types.state :=
            {
              !(session.state) with
              config = Some { config with Api.graph_name = name };
            }
        | Error message ->
          debug ("graph catalog refresh failed: " ^ message));
       graph_catalog_snapshot session
     | None -> graph_catalog_snapshot session)
  | "createSyncGraph" ->
    Rpc.create_sync_graph s.config payload h.send
      h.Types.ensure_user_keys
      h.Types.provision_graph_key
      (fun config encrypted ->
        Rpc.upload_initial_graph_snapshot config encrypted
          h.encrypt_title h.upload_file h.cleanup_file)
      (fun config -> discover_graphs session config)
      (fun config ->
        session.Types.state :=
          {
            !(session.state) with
            accepted_server_t = None;
            config = Some config;
          };
        snapshot_visible session)
  | "selectGraph" -> select_graph session payload
  | "ensureJournal" -> ensure_journal session payload
  | "setJournalTitleFormat" ->
    with_object "setJournalTitleFormat" payload "A date format is required"
      (fun _ fields -> set_journal_title_format session fields)
  | "selectPage" -> select_page session payload
  | "hydrateOutlinerRows" -> hydrate_outliner_rows session payload
  | "queryBlock" ->
    (match payload, query_db session with
     | Some uuid, Some db -> success session (Rpc.json_object ["query",
         Option.value ~default:`Null (query_for session db uuid)])
     | None, _ -> Rpc.failure "invalid_params" "A query block UUID is required"
     | _, None -> Rpc.failure "graph_unavailable" "No graph is open")
  | "nodeProperties" ->
    (match payload, query_db session with
     | Some owner, Some db -> (match Node_property.render db ~owner ~encode_block:(result_block_encoder db) with
         | Ok value -> success session (`Assoc ["nodeProperties", value])
         | Error message -> Rpc.failure "invalid_property" message)
     | _ -> Rpc.failure "graph_unavailable" "No graph is open")
  | "nodeProperty" ->
    (match payload, query_db session with
     | Some payload, Some db ->
       (try match editing_cursor session with
         | Error (code, message) -> Rpc.failure code message
         | Ok cursor -> (match Node_property.mutation db ~now:(now_ms ()) ~fresh_uuid:fresh_squuid (Json.from_string payload) with
             | Ok intent -> stage_result session (fresh_squuid ()) cursor intent
             | Error message -> Rpc.failure "invalid_property" message)
        with error -> Rpc.failure "invalid_property" (Printexc.to_string error))
     | _ -> Rpc.failure "graph_unavailable" "No graph is open")
  | "resultViews" ->
    (match payload, query_db session with
     | Some payload, Some db ->
       (try let json = Json.from_string payload in
         let string key = match json with `Assoc fields ->
           (match List.assoc_opt key fields with Some (`String s) -> s | _ -> "") | _ -> "" in
         (match Result_view.render ~input:(string "input") db ~owner:(string "ownerUuid")
           ~feature:(string "featureType") ~encode_block:Rpc.block_json with
          | Ok value -> success session value
          | Error message -> Rpc.failure "invalid_view" message)
        with error -> Rpc.failure "invalid_view" (Printexc.to_string error))
     | _ -> Rpc.failure "graph_unavailable" "No graph is open")
  | "resultView" ->
    (match payload, query_db session with
     | Some payload, Some db ->
       (try
         let input = Json.from_string payload in
         let get name = match input with `Assoc fields -> Option.value ~default:`Null (List.assoc_opt name fields) | _ -> `Null in
         if get "action" = `String "setExpanded" then (
           match get "ownerUuid", get "featureType", get "expanded" with
           | `String uuid, `String "query-result", `Bool expanded when Query_block.is_query db uuid ->
             let key = query_expansion_key session uuid in
             let current = state session in
             session.Types.state := {current with expanded_queries =
               (if expanded then Outliner.Sset.add else Outliner.Sset.remove) key current.expanded_queries};
             snapshot_visible session
           | _ -> Rpc.failure "invalid_query" "A query block and expansion state are required")
         else match editing_cursor session with
           | Error (code, message) -> Rpc.failure code message
           | Ok cursor ->
             (match Result_view.mutation db ~now:(now_ms ()) ~fresh_uuid:fresh_squuid input with
              | Ok intent -> stage_result session (fresh_squuid ()) cursor intent
              | Error message -> Rpc.failure "invalid_view" message)
        with error -> Rpc.failure "invalid_view" (Printexc.to_string error))
     | _ -> Rpc.failure "graph_unavailable" "No graph is open")
  | "cachedImageGallery" ->
    (match payload with Some uuid -> cached_image_gallery session uuid
     | None -> Rpc.failure "invalid_params" "An image UUID is required")
  | "prepareAssetDownload" ->
    with_object action payload "Asset metadata is required" (fun _input fields -> graph_asset session fields false)
  | "cacheDownloadedAsset" ->
    with_object action payload "Asset download is required" (fun _input fields -> graph_asset session fields true)
  | "loadPageReferences" ->
    (match payload with
     | None -> Rpc.failure "invalid_params" "A page UUID is required"
     | Some uuid ->
       So.load_page_references session uuid;
       let blocks = So.references_for_node session uuid in
       let serialize = window_serializer session Rpc.visible_block_json blocks in
       success session (Rpc.json_object [
         "isReferencePatch", `Bool true; "referenceUuid", `String uuid;
         "selectedGraphId", (match (state session).config with
           | Some config -> `String config.Api.graph_id | None -> `Null);
         "referenceBlocks", Rpc.json_list (List.map serialize blocks)]))
  | "openNode" ->
    with_object action payload "openNode requires a node id"
      (fun _input fields -> open_node session fields)
  | "closeNode" ->
    pop_node_route session;
    snapshot_visible session
  | "clearSelectedPage" ->
    clear_node_navigation session;
    session.Types.state :=
      { !(session.state) with selected_sidebar_page = None };
    reset_outliner session;
    snapshot_visible session
  | "loadOlderJournals" ->
    (match h.Types.load_older_journals with
     | Some load -> load ()
     | None -> ());
    snapshot_visible session
  | "loadSidebar" -> sidebar_snapshot session
  | "loadFlashcards" ->
    let now =
      match payload with
      | Some value ->
        (match int_of_string_opt value with
         | Some now -> now
         | None -> now_ms ())
      | None -> now_ms ()
    in
    reload_flashcards session now;
    debug
      ("loadFlashcards count="
       ^ string_of_int (List.length (state session).flashcards)
       ^ " now=" ^ string_of_int now);
    snapshot_visible session
  | "reviewFlashcard" ->
    Rpc.review_flashcard payload h.Types.graph_review_flashcard now_ms
      (fun now ->
        if (state session).config <> None then
          restore_semantic_queue session;
        reload_flashcards session now;
        snapshot_visible session)
  | "setPageFavorite" ->
    Rpc.set_page_favorite payload h.Types.graph_set_page_favorite
      (s.config <> None) now_ms
      (fun () ->
        if (state session).config <> None then
          restore_semantic_queue session;
        snapshot_visible session)
  | "deletePage" ->
    Rpc.delete_page payload h.Types.graph_delete_page
      (s.config <> None) now_ms
      (fun () ->
        if (state session).config <> None then
          restore_semantic_queue session;
        snapshot_visible session)
  | "unlockGraph" ->
    (match (s.config, h.Types.unlock_graph, payload) with
     | Some config, Some unlock, Some password ->
       if selected_graph_is_encrypted session then
         match unlock config password with
         | Ok () -> snapshot_visible session
         | Error message -> Rpc.failure "graph_unlock_failed" message
       else snapshot_visible session
     | _ ->
       if s.config <> None && not (selected_graph_is_encrypted session)
       then snapshot_visible session
       else if h.unlock_graph = None then
         Rpc.failure "graph_unlock_unavailable"
           "Graph unlock is unavailable"
       else
         Rpc.failure "invalid_params"
           "unlockGraph requires a selected graph and password")
  | "importSnapshot" ->
    let forced, graph_id, generation = match payload with
      | Some body -> (try
          let input = Yojson.Basic.from_string body in
          (Yojson.Basic.Util.member "forceSnapshot" input = `Bool true,
           Yojson.Basic.Util.member "graphId" input, Yojson.Basic.Util.member "generation" input)
        with _ -> (false, `Null, `Null))
      | None -> (false, `Null, `Null) in
    let graph_changed = match s.config, graph_id with
      | Some config, `String id -> id <> config.Api.graph_id
      | _ -> false in
    let stale_generation = match generation with `Int value -> value <> s.bootstrap_generation | _ -> false in
    if graph_changed || stale_generation then
      Rpc.failure "graph_changed" "The graph operation changed during snapshot download"
    else if forced && sync_transport_editing session then
      Rpc.failure "snapshot_deferred" "Snapshot import waits for editing to finish"
    else Rpc.import_snapshot payload h.Types.import_snapshot
      (fun payload -> switch_graph_model session payload)
      (fun () -> sidebar_snapshot session)
  | "openGraph" ->
    Rpc.open_graph payload h.Types.open_graph
      (fun payload -> switch_graph_model session payload)
      (fun () -> snapshot_visible session)
  | "startWebSocket" ->
    session.Types.state := { !(session.state) with sync_connected = true };
    snapshot_visible session
  | "applySyncEvent" ->
    Rpc.apply_sync_event payload h.Types.apply_sync_event (fun () ->
        reconcile_authoritative_blocks session;
        snapshot_visible session)
  | "stopWebSocket" ->
    session.Types.state := { !(session.state) with sync_connected = false };
    snapshot_visible session
  | "searchNodes" | "searchNodesPage" ->
    let query, offset = if action = "searchNodes" then Option.value ~default:"" payload, 0
      else match payload with
        | None -> "", -1
        | Some payload -> (try
          let json = Yojson.Basic.from_string payload in
          let query = Yojson.Basic.Util.member "query" json |> Yojson.Basic.Util.to_string in
          let offset = Yojson.Basic.Util.member "offset" json |> Yojson.Basic.Util.to_int in
          query, offset with _ -> "", -1) in
    let valid = offset = 0 || (offset = s.search_result_count && query = s.search_query) in
    let found, has_more =
      if not valid || String_kit.is_blank query then [], false
      else match h.Types.graph_search_page with
      | Some search -> search ~offset ~limit:20 query
      | None ->
        let all = match h.Types.graph_search with Some search -> search query | None -> [] in
        let rec slice skip remaining acc = function
          | [] -> List.rev acc, false
          | _ when remaining = 0 && skip = 0 -> List.rev acc, true
          | _ :: rest when skip > 0 -> slice (skip - 1) remaining acc rest
          | hit :: rest -> slice 0 (remaining - 1) (hit :: acc) rest in
        slice offset 20 [] all in
    if valid then session.Types.state :=
      { !(session.state) with search_query = query; search_has_more = has_more;
        search_result_pages = (if offset = 0 then [found] else found :: s.search_result_pages);
        search_result_count = offset + List.length found };
    if h.Types.outliner_projection_limit = None then snapshot_visible session
    else success session (Rpc.json_object ["isSearchPatch", `Bool true;
      "selectedGraphId", (match (state session).config with Some config -> `String config.Api.graph_id | None -> `Null);
      "searchQuery", `String query; "searchOffset", `Int offset; "searchHasMore", `Bool has_more;
      "searchResults", Rpc.json_list (List.map Rpc.search_hit_json found)])
  | "composerTags" -> composer_tags session
  | "sendTagged" -> object_action (send_tagged session)
  | "send" -> send_message session payload
  | "sendTask" -> object_action (send_task session)
  | "addAsset" ->
    let prepare_view () =
      let before = outliner_context session in
      let previous = (state session).outliner_state in
      fun () ->
        let s = state session in
        if s.selected_sidebar_page = None && s.node_routes = [] then
          structural_outliner_patch false session before previous
            (outliner_context session)
        else snapshot_visible session
    in
    let target uuid =
      List.find_opt
        (fun block -> block.Model.uuid = uuid)
        (base_outliner_context session).Outliner.blocks
    in
    let stage () =
      if (state session).config = None then None else
      Option.map (fun stage operation ->
        let tags = Option.bind payload (fun raw -> try match Json.from_string raw with
          | `Assoc fields -> List.assoc_opt "tags" fields | _ -> None with _ -> None) in
        match tags with
        | None -> stage operation
        | Some tags ->
          let ( let* ) = Result.bind in
          let uuid = match operation.Ops.intent with Ops.Create_asset asset -> asset.uuid | _ -> "" in
          let* intent = prepare_capture_tags session uuid tags operation (now_ms ()) in
          let* () = stage operation in
          stage {operation with Ops.operation_id = fresh_squuid (); state = Ops.Queued; intent})
        (host session).Types.stage_operation
    in
    Rpc.add_asset ~prepare_file:h.import_asset_file payload s.model now_ms target prepare_view
      (fun block -> asset_datoms_operation session block Ops.Applied)
      stage
  | "addChildBlock" ->
    Rpc.add_child_block payload s.model now_ms
      (fun () ->
        ((state session).config, projection_server_t session))
      (child_context session)
      (fun _config operation -> enqueue_semantic session operation)
      fresh_squuid (fun () -> snapshot_visible session)
  | "beginPendingSync" ->
    (match s.config with
     | Some config ->
       (match resolve_graph config with
        | Ok config -> begin_pending_sync session config
        | Error _ -> ())
     | None -> ());
    pending_sync_patch session
  | "completePendingSync" ->
    (match payload with
     | Some payload ->
       let semantic = s.semantic_active <> None in
       (match complete_pending_sync session payload with
        | Ok () ->
          if semantic && h.Types.apply_sync_event = None then pending_sync_patch session
          else if semantic then begin
            reconcile_authoritative_blocks session;
            snapshot_visible session
          end
          else snapshot_visible session
        | Error message ->
          Rpc.failure "invalid_pending_sync_completion" message)
     | None ->
       Rpc.failure "invalid_params"
         "completePendingSync requires a JSON payload")
  | "cancelPendingSync" ->
    cancel_pending_sync session;
    snapshot_visible session
  | "clearRelated" ->
    session.Types.state := { !(session.state) with related_blocks = [] };
    snapshot_visible session
  | "updateBlockStatus" -> object_action (update_block_status session)
  | "updateBlock" -> object_action (update_block session)
  | "splitBlock" ->
    object_action (fun _input fields -> split_block session fields)
  | "mergeBackward" ->
    object_action (fun _input fields -> merge_backward session fields)
  | "moveBlocks" -> object_action (move_blocks session)
  | "deleteBlocks" -> object_action (delete_blocks session)
  | "deleteBlock" ->
    object_action (fun _input fields -> delete_block session fields)
  | "select" ->
    (match payload with
     | Some uuid ->
       (match Model.select s.model uuid with
        | Ok () -> snapshot_visible session
        | Error message -> Rpc.failure "unknown_block" message)
     | None ->
       Rpc.failure "invalid_params" "select requires a block uuid")
  | "clearSelection" ->
    Model.clear_selection s.model;
    snapshot_visible session
  | _ -> Rpc.failure "unknown_action" ("unknown action: " ^ action)

let call session request =
  Rpc.call
    (fun () -> snapshot_visible session)
    (fun action payload -> dispatch session action payload)
    request
