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
           ; ("breadcrumbs", Rpc.json_list (List.map Rpc.summary_json (route_breadcrumbs context route)))
           ; ("scrollTarget", match route.scroll_target with Some uuid -> `String uuid | None -> `Null)
           ; ("isTag", `Bool route.is_tag)
           ; ("isProperty", `Bool route.is_property)
           ; ("page", Rpc.summary_json route.page)
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

let trace_snapshot started stage =
  if Sys.getenv_opt "LOGSEQ_TRACE_STARTUP" = Some "1" then
    prerr_endline
      ("LOGSEQ_SNAPSHOT_METRIC stage=" ^ stage
       ^ Printf.sprintf " elapsed_ms=%.3f"
           ((Unix.gettimeofday () -. started) *. 1000.0))

let snapshot session context_blocks blocks =
  let started = Unix.gettimeofday () in
  let s = state session in
  let h = host session in
  let sidebar = sidebar_pages session in
  trace_snapshot started "sidebar";
  let current =
    match s.node_base_state with
    | Some base -> base
    | None -> s.outliner_state
  in
  let context =
    base_outliner_context_with_blocks session (Some sidebar) context_blocks
  in
  trace_snapshot started "context";
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
    Rpc.success
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
         ; ("selectedPageIsTag", `Bool (selected_page_is_tag session))
         ; ( "selectedPageIsProperty"
           , `Bool (selected_page_is_property session) )
         ; ("searchQuery", `String s.search_query)
         ; ( "searchResults"
           , Rpc.json_list (List.map Rpc.search_hit_json s.search_results)
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
               (List.map Rpc.summary_json sidebar.Graph_read.favorites) )
         ; ( "recentPages"
           , Rpc.json_list
               (List.map Rpc.summary_json sidebar.Graph_read.recent_pages)
           )
         ; ( "selectedPage"
           , match s.selected_sidebar_page with
             | Some page -> Rpc.summary_json page
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
         ; ( "taskStatuses"
           , Rpc.json_list
               (List.map Rpc.status_response_json
                  (Model.all_statuses s.model)) )
         ; ("pendingSyncError", match s.pending_sync_error with Some message -> `String message | None -> `Null)
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
  Rpc.outliner_patch_result s.model.revision context s.outliner_state
    s.outliner_revision s.outliner_commands
    (has_pending_operations session)
    blocks deleted splices

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
  let started = Unix.gettimeofday () in
  let s = state session in
  let h = host session in
  let context_blocks =
    match (s.selected_sidebar_page, h.Types.graph_page_blocks) with
    | Some page, Some load ->
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
  trace_snapshot started "blocks";
  let result = snapshot session context_blocks blocks in
  trace_snapshot started "complete";
  result

let graph_catalog_snapshot session =
  let s = state session in
  Rpc.success
    (Rpc.json_object
       [
         ( "graphName"
         , match s.config with
           | Some config ->
             (match config.Api.graph_name with
              | Some name -> `String name
              | None -> `Null)
           | None -> `Null )
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
  Rpc.success
    (Rpc.json_object
       [
         ("revision", `Int (state session).model.revision)
       ; ("blocks", Rpc.json_list [])
       ; ("selectedBlock", `Null)
       ; ( "appliedServerT"
         , match projection_server_t session with
           | Some value -> `Int value
           | None -> `Null )
       ; ("pendingSyncError", match (state session).pending_sync_error with Some message -> `String message | None -> `Null)
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
      let context, aggregate =
        match aggregate_return_context session payload message with
        | Some (context, uuid) -> (context, Some uuid)
        | None -> (outliner_context session, None)
      in
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
           session.Types.state :=
             {
               !(session.state) with
               outliner_state = next_state;
               outliner_optimistic_blocks =
                 Some projected.Outliner.blocks;
               outliner_commands = interpreted.platform;
               outliner_revision =
                 (state session).outliner_revision + 1;
             };
           if (state session).node_routes <> [] then
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
        if Hashtbl.mem wanted block.uuid then Hashtbl.replace found block.uuid block) blocks in
      collect (outliner_context session).Outliner.blocks;
      if Hashtbl.length found < Hashtbl.length wanted then collect (base_outliner_context session).Outliner.blocks;
      if Hashtbl.length found < Hashtbl.length wanted then collect (snapshot_related_blocks session);
      if Hashtbl.length found < Hashtbl.length wanted then collect (snapshot_linked_reference_blocks session);
      List.iter (fun route ->
        if Hashtbl.length found < Hashtbl.length wanted then collect (node_route_context session route).Outliner.blocks;
        if Hashtbl.length found < Hashtbl.length wanted then collect (node_route_related_blocks session route);
        if Hashtbl.length found < Hashtbl.length wanted then collect (node_route_linked_reference_blocks session route)) (state session).node_routes;
      Rpc.success (Rpc.json_object ["isOutlinerContentPatch", `Bool true;
        "selectedGraphId", (match (state session).config with Some config -> `String config.Api.graph_id | None -> `Null);
        "hydratedBlocks", Rpc.json_list (List.filter_map (fun id ->
          Option.map Rpc.visible_block_json (Hashtbl.find_opt found id)) ids)])
  with Yojson.Json_error message -> Rpc.failure "invalid_params" message

let asset_cache_path session graph_id uuid asset_type =
  (host session).resolve_asset_path
    (Filename.concat "Assets" (Filename.concat (Api.url_encode graph_id)
      (Api.url_encode uuid ^ "." ^ Api.url_encode (Api.normalize_asset_type asset_type))))

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
        let cached = asset_cache_path session config.Api.graph_id block.uuid kind in
        let local = Option.map (host session).resolve_asset_path block.local_path in
        let path = match local with Some path when Sys.file_exists path -> path | _ -> cached in
        if Sys.file_exists path then Some (block, path) else None) blocks
      |> List.sort (fun (a, _) (b, _) -> compare (a.Model.order, a.uuid) (b.Model.order, b.uuid)) in
    let index = ref (-1) in
    let paths = List.mapi (fun position (block, path) ->
      if block.Model.uuid = uuid then index := position;
      `String path) images in
    if !index < 0 then Rpc.failure "asset_unavailable" "The image is not cached"
    else Rpc.success (Rpc.json_object ["paths", Rpc.json_list paths; "selectedIndex", `Int !index])
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
      let path = asset_cache_path session graph_id uuid kind in
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
  | Ok value -> Rpc.success value
  | Error "graph_changed" -> Rpc.failure "graph_changed" "The active graph changed during asset download"
  | Error message -> Rpc.failure "asset_download_failed" message

let ensure_journal session payload =
  let day = Option.bind payload int_of_string_opt in
  let valid day =
    let year = day / 10000 and month = day / 100 mod 100 and date = day mod 100 in
    let leap = year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0) in
    let days = [|31; (if leap then 29 else 28); 31; 30; 31; 30; 31; 31; 30; 31; 30; 31|] in
    year >= 1 && year <= 9999 && month >= 1 && month <= 12
    && date >= 1 && date <= days.(month - 1)
  in
  match day with
  | None -> Rpc.failure "invalid_params" "A journal date is required"
  | Some day when not (valid day) -> Rpc.failure "invalid_params" "The journal date is invalid"
  | Some day ->
    let existing = Option.bind (host session).Types.journal_page_id (fun find -> find day) in
    let result = match existing, projection_server_t session, (state session).config with
      | Some uuid, _, _ -> Ok uuid
      | None, Some base_t, Some _ ->
        let uuid = Rpc.journal_page_uuid day in
        let operation = { Ops.operation_id = fresh_squuid ();
          base_t; state = Ops.Queued;
          intent = Ops.Create_journal { Ops.page_uuid = uuid; block_uuid = fresh_squuid ();
            title = Rpc.journal_day_title day; journal_day = day; created_at = now_ms () } } in
        Result.map (fun () -> uuid) (enqueue_semantic session operation)
      | None, _, _ -> Error "Select a graph before creating a journal"
    in
    match result with
    | Ok uuid -> Rpc.success (Rpc.json_object ["uuid", `String uuid])
    | Error message -> Rpc.failure "journal_creation_failed" message

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

let dispatch session action payload =
  let s = state session in
  let h = host session in
  let object_action handle =
    with_object action payload
      (action ^ " requires a JSON payload")
      handle
  in
  match action with
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
  | "selectPage" -> select_page session payload
  | "hydrateOutlinerRows" -> hydrate_outliner_rows session payload
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
       Rpc.success (Rpc.json_object [
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
  | "loadSidebar" ->
    session.Types.state :=
      { !(session.Types.state) with Types.sidebar_deferred = false };
    snapshot_visible session
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
    Rpc.import_snapshot payload h.Types.import_snapshot
      (fun payload -> switch_graph_model session payload)
      (fun () -> snapshot_visible session)
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
  | "searchNodes" ->
    let query = match payload with Some q -> q | None -> "" in
    let found =
      if String_kit.is_blank query then []
      else
        match h.Types.graph_search with
        | Some search -> search query
        | None -> []
    in
    session.Types.state :=
      { !(session.state) with search_query = query; search_results = found };
    if h.Types.outliner_projection_limit = None then snapshot_visible session
    else Rpc.success (Rpc.json_object ["isSearchPatch", `Bool true;
      "selectedGraphId", (match (state session).config with Some config -> `String config.Api.graph_id | None -> `Null);
      "searchQuery", `String query; "searchResults", Rpc.json_list (List.map Rpc.search_hit_json found)])
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
      if (state session).config <> None then
        (host session).Types.stage_operation
      else None
    in
    Rpc.add_asset payload s.model now_ms target prepare_view
      (fun block -> asset_datoms_operation session block Ops.Applied)
      stage
  | "addChildBlock" ->
    Rpc.add_child_block payload s.model now_ms
      (fun () ->
        ((state session).config, projection_server_t session))
      (fun () -> outliner_context session)
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
