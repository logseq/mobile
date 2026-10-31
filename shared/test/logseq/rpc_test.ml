open Test_util

module Ds = Datascript
module Rpc = Rpc
module Session = Rpc_session
module Types = Session_types
module Graph = Graph_read
module Fractional = Fractional_order
module Ops = Pending_ops
module Model = Cache_model
module Api = Api
module Search = Search_index
module Effects = Outliner_effects
module Sync_session = Sync_session
module Codec = Storage_codec
module Outliner = Outliner_state
module Flashcards = Flashcards
module Value = Transit_core.Json
module Json = Yojson.Basic
module Json_util = Yojson.Basic.Util

let member key json = match json with `Assoc _ -> Json_util.member key json | _ -> `Null
let json_items key value = Json_util.to_list (member key value)
let json_string value = Json_util.to_string value

let dispatch_json session action payload =
  Json.from_string
    (Session.call session
       (Json.to_string
          (Rpc.json_object
             [
               ("apiVersion", `Int 1);
               ("method", `String "dispatch");
               ( "params",
                 Rpc.json_object
                   [
                     ("action", `String action);
                     ("payload", `String payload);
                   ] );
             ])))

let response_result response =
  check (Json_util.to_bool (member "ok" response));
  member "result" response

let pending_request response =
  match member "pendingSyncRequest" (member "result" response) with
  | `Null -> None
  | value -> Some value

let plain_graph_catalog =
  "{\"graphs\":[{\"graph-id\":\"plain-1\",\"graph-name\":\"Plain\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}"

let encrypted_graph_catalog =
  "{\"graphs\":[{\"graph-id\":\"encrypted-1\",\"graph-name\":\"Private\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":true}]}"

let plain_session () =
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
      }
  in
  ignore
    (dispatch_json session "configure"
       "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}");
  session

let configure_plain_session session =
  ignore
    (dispatch_json session "configure"
       "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}");
  session

let configure_encrypted_session session =
  ignore
    (dispatch_json session "configure"
       "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"\",\"token\":\"access\"}");
  session

let response_error_code response =
  json_string (member "code" (member "error" response))

let synced_block uuid title =
  {
    (Model.local_block uuid title "page" (Some "page") 1) with
    Model.order = Some "a0";
    sync_status = "synced";
  }

let prepare_operation operation =
  Ok (Ops.outliner_op operation.Ops.intent, "[]")

let outliner_event session payload =
  response_result (dispatch_json session "outlinerEvent" payload)

let outliner_block_event session event uuid =
  outliner_event session
    (Json.to_string
       (Rpc.json_object
          ([ ("type", `String event); ("uuid", `String uuid) ]
           @
           if event = "backspacePressed" then
             [ ("selectionLength", `Int 0) ]
           else [])))

let editing_uuid response =
  json_string
    (member "uuid" (member "editing" (member "outlinerState" response)))

let first_node_route response = List.hd (json_items "nodeRoutes" response)

let node_row_ids response =
  List.map
    (fun row -> json_string (member "uuid" (member "block" row)))
    (json_items "outlinerRows" (first_node_route response))

let required_matching_item pred items =
  match List.find_opt pred items with
  | Some item -> item
  | None -> failwith "missing projected item"

let assert_bounded_structural_patch response =
  check_eq (member "isOutlinerPatch" response) (`Bool true);
  check (json_items "outlinerRows" response = []);
  check (List.length (json_items "blocks" response) <= 2);
  let splices = json_items "outlinerRowSplices" response in
  check_eq (List.length splices) 1;
  check (List.length (json_items "rows" (List.hd splices)) <= 2)

let required_pending_request session =
  match pending_request (dispatch_json session "beginPendingSync" "") with
  | Some request -> request
  | None -> failwith "expected a pending sync request"

let complete_request session request body =
  response_result
    (dispatch_json session "completePendingSync"
       (Json.to_string
          (Rpc.json_object
             [
               ("id", member "id" request);
               ("status", `Int 200);
               ("body", `String body);
               ("error", `Null);
             ])))

let retryable_operation (operation : Ops.pending_operation) =
  match operation.state with
  | Ops.Queued | Ops.Retryable | Ops.Submitted -> true
  | _ -> false

let staging_session cursor blocks staged =
  configure_plain_session
    (Session.create_session
       {
         Session.default_options with
         load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
         sync_cursor = Some (fun () -> Some cursor);
         graph_blocks = Some (fun () -> Some !blocks);
         stage_operation =
           Some (fun operation -> staged := !staged @ [ operation ]; Ok ());
         prepare_operation = Some prepare_operation;
       })

let assert_semantic_request session operation_id outliner_op cursor =
  let request = required_pending_request session in
  let body = member "bodyObject" request in
  let tx = List.hd (json_items "txs" body) in
  check_eq (member "method" request) (`String "WS");
  check_eq (member "t-before" body) (`Int cursor);
  check_eq (member "tx-id" tx) (`String operation_id);
  check_eq (member "outliner-op" tx) (`String outliner_op)

(* Tests *)

let semantic_completion_preserves_error_and_status_precedence () =
  List.iter
    (fun (wire, expected) ->
      check_eq
        (Session.parse_semantic_completion (Json.from_string wire) 1)
        expected)
    [
      ("{\"id\":1,\"error\":\"\",\"status\":200}", Ok (true, None));
      ("{\"id\":1,\"error\":\" \"}", Ok (false, None));
      ("{\"id\":1,\"error\":false,\"status\":299}", Ok (true, None));
      ("{\"id\":1,\"status\":300}", Ok (false, None));
      ( "{\"id\":1,\"error\":\"\"}",
        Error "pending transport returned no HTTP status" );
      ( "{\"id\":2,\"error\":\"failed\"}",
        Error "pending sync request id does not match" );
      ("{}", Error "pending sync completion requires id");
      ("null", Error "pending sync completion must be an object");
    ]

let required_string_lists_preserve_order_and_validate_every_item () =
  check_eq
    (Rpc.required_string_list "uuids" (Json.from_string "{\"uuids\":[]}"))
    (Ok []);
  check_eq
    (Rpc.required_string_list "uuids"
       (Json.from_string "{\"uuids\":[\" b \",\"a\",\"a\"]}"))
    (Ok [ " b "; "a"; "a" ]);
  List.iter
    (fun wire ->
      check_eq
        (Rpc.required_string_list "uuids" (Json.from_string wire))
        (Error "field must be a list: uuids"))
    [ "{}"; "{\"uuids\":null}"; "{\"uuids\":1}" ];
  List.iter
    (fun wire ->
      check_eq
        (Rpc.required_string_list "uuids" (Json.from_string wire))
        (Error "field must be a list of non-empty strings: uuids"))
    [
      "{\"uuids\":[\"\"]}";
      "{\"uuids\":[\" \"]}";
      "{\"uuids\":[\"a\",null]}";
    ]

let move_payloads_preserve_order_and_first_validation_error () =
  check_eq (Rpc.required_moves (Json.from_string "{\"moves\":[]}")) (Ok []);
  let move : Ops.pending_move =
    { uuid = "a"; page_uuid = "page"; parent_uuid = "parent"; order = "a0" }
  in
  let wire =
    "{\"moves\":[{\"uuid\":\"a\",\"pageUuid\":\"page\",\"parentUuid\":\"parent\",\"order\":\"a0\"},{\"uuid\":\"a\",\"pageUuid\":\"page\",\"parentUuid\":\"parent\",\"order\":\"a0\"}]}"
  in
  check_eq (Rpc.required_moves (Json.from_string wire)) (Ok [ move; move ]);
  List.iter
    (fun (wire, message) ->
      check_eq (Rpc.required_moves (Json.from_string wire)) (Error message))
    [
      ("{}", "field must be a list: moves");
      ("{\"moves\":[null]}", "moves must contain objects");
      ("{\"moves\":[{},null]}", "missing field: uuid");
      ("{\"moves\":[{\"uuid\":1,\"pageUuid\":1}]}", "field must be a string: uuid");
      ("{\"moves\":[{\"uuid\":\"a\"}]}", "missing field: pageUuid");
      ("{\"moves\":[{\"uuid\":\"a\",\"pageUuid\":\"p\"}]}", "missing field: parentUuid");
      ( "{\"moves\":[{\"uuid\":\"a\",\"pageUuid\":\"p\",\"parentUuid\":\"p\"}]}",
        "missing field: order" );
    ]

let status_payload_preserves_validation_and_optional_fields () =
  List.iter
    (fun (wire, message) ->
      check_eq (Rpc.status_payload (Json.from_string wire)) (Error message))
    [
      ("{}", "missing field: status");
      ("{\"status\":null}", "missing field: status");
      ("{\"status\":{}}", "missing field: uuid");
      ("{\"status\":{\"uuid\":1,\"title\":1}}", "field must be a string: uuid");
      ("{\"status\":{\"uuid\":\"s\"}}", "missing field: title");
      ( "{\"status\":{\"uuid\":\"s\",\"title\":\"Todo\",\"ident\":1}}",
        "field must be a string: ident" );
      ( "{\"status\":{\"uuid\":\"s\",\"title\":\"Todo\",\"iconColor\":false}}",
        "field must be a string: iconColor" );
    ];
  let wire =
    Json.from_string
      "{\"status\":{\"uuid\":\"s\",\"title\":\"Todo\",\"ident\":\"todo\",\"iconType\":\"tabler-icon\",\"iconId\":\"circle\",\"iconColor\":\"red\"}}"
  in
  let expected : Model.status =
    {
      uuid = "s";
      title = "Todo";
      ident = Some "todo";
      icon_type = Some "tabler-icon";
      icon_id = Some "circle";
      icon_color = Some "red";
    }
  in
  check_eq (Rpc.status_payload wire) (Ok expected);
  check_eq (Rpc.optional_status_payload wire) (Ok (Some expected));
  List.iter
    (fun wire ->
      check_eq (Rpc.optional_status_payload (Json.from_string wire)) (Ok None))
    [ "{}"; "{\"status\":null}" ];
  check_eq
    (Rpc.optional_status_payload (Json.from_string "{\"status\":{}}"))
    (Error "missing field: uuid")

let status_reference_prefers_nonblank_ident_without_trimming_it () =
  let status : Model.status =
    {
      uuid = "s";
      title = "Todo";
      ident = None;
      icon_type = None;
      icon_id = None;
      icon_color = None;
    }
  in
  List.iter
    (fun ident ->
      check_eq
        (Rpc.status_semantic_ref { status with ident = Some ident })
        (Ops.Ref_uuid "s"))
    [ ""; " \n\t" ];
  check_eq (Rpc.status_semantic_ref status) (Ops.Ref_uuid "s");
  check_eq
    (Rpc.status_semantic_ref { status with ident = Some " todo " })
    (Ops.Ref_ident " todo ")

let journal_identifiers_and_titles_preserve_wire_format () =
  check_eq (Rpc.journal_page_uuid 20260916) "00000001-2026-0916-0000-000000000000";
  List.iter
    (fun (day, title) -> check_eq (Rpc.journal_day_title day) title)
    [
      (20260101, "Jan 1st, 2026");
      (20260202, "Feb 2nd, 2026");
      (20260303, "Mar 3rd, 2026");
      (20260411, "Apr 11th, 2026");
      (20260512, "May 12th, 2026");
      (20260613, "Jun 13th, 2026");
      (20260721, "Jul 21st, 2026");
      (20260822, "Aug 22nd, 2026");
      (20260923, "Sep 23rd, 2026");
      (20261024, "Oct 24th, 2026");
      (20261130, "Nov 30th, 2026");
      (20261231, "Dec 31st, 2026");
    ];
  List.iter
    (fun day ->
      check
        (try
           ignore (Rpc.journal_day_title day);
           false
         with _ -> true))
    [ 20260001; 20261301 ]

let pending_version_compares_content_and_asset_identity () =
  let block = Model.local_block "b" "Title" "page" None 10 in
  let status : Model.status =
    {
      uuid = "s";
      title = "Todo";
      ident = None;
      icon_type = None;
      icon_id = None;
      icon_color = None;
    }
  in
  let tagged = { block with Model.status = Some status } in
  check (Rpc.same_pending_version block block);
  check
    (Rpc.same_pending_version tagged
       { tagged with status = Some { status with title = "Renamed" } });
  List.iter
    (fun changed -> check (not (Rpc.same_pending_version block changed)))
    [
      { block with uuid = "other" };
      { block with title = "Changed" };
      { block with updated_at = 11 };
      tagged;
      { block with asset_size = Some 2 };
      { block with asset_checksum = Some "hash" };
      { block with local_path = Some "file" };
    ];
  check (not (Rpc.same_pending_version tagged block))

let structural_events_preserve_source_and_ignore_other_event_types () =
  List.iter
    (fun kind ->
      check_eq
        (Rpc.outliner_structure_source
           (Printf.sprintf "{\"type\":\"%s\",\"uuid\":\"b\"}" kind))
        (Some "b"))
    [ "returnPressed"; "backspacePressed" ];
  List.iter
    (fun wire -> check (Rpc.outliner_structure_source wire = None))
    [
      "null";
      "[]";
      "{}";
      "{\"type\":\"returnPressed\"}";
      "{\"type\":\"returnPressed\",\"uuid\":1}";
      "{\"type\":\"textChanged\",\"uuid\":\"b\"}";
    ]

let authoritative_reconciliation_preserves_newer_local_edits () =
  let cache = Model.create None in
  let same = Model.local_block "same" "Same" "page" None 1 in
  let changed = Model.local_block "changed" "Local" "page" None 1 in
  let submitted =
    {
      (Model.local_block "submitted" "Local" "page" None 1) with
      Model.sync_status = "submitted";
    }
  in
  let missing = Model.local_block "missing" "Missing" "page" None 1 in
  Model.upsert_blocks cache [ same; changed; submitted; missing ] 1;
  Rpc.reconcile_authoritative_blocks cache
    [
      same;
      { changed with title = "Remote" };
      { submitted with title = "Remote" };
    ];
  List.iter
    (fun (uuid, expected) ->
      check_eq
        (match Model.read_block cache uuid with
         | Some block -> Some block.Model.sync_status
         | None -> None)
        (Some expected))
    [
      ("same", "synced");
      ("changed", "pending");
      ("submitted", "synced");
      ("missing", "pending");
    ]

let node_navigation_preserves_independent_projections_and_editing () =
  let page : Model.entity_summary = { uuid = "page-1"; title = "Page one" } in
  let block =
    {
      (Model.local_block "block-1" "Referenced block" "page-1" None 1) with
      Model.parent_id = Some "page-1";
      order = Some "a0";
      sync_status = "synced";
      breadcrumbs = [ page ];
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_node_destination =
          Some
            (fun uuid ->
              if uuid = "block-1" then Some (page, true)
              else if uuid = "page-1" || uuid = "tag-1" then Some (page, false)
              else None);
        graph_page_blocks =
          Some (fun uuid -> if uuid = "page-1" then Some [ block ] else None);
        graph_tag_pages =
          Some
            (fun () ->
              Some
                [ ({ uuid = "tag-1"; title = "Tag one" } : Model.entity_summary) ]);
        graph_node_is_tag = Some (fun uuid -> uuid = "tag-1");
        graph_node_references =
          Some (fun uuid -> if uuid = "block-1" then Some [ block ] else None);
        graph_tag_objects =
          Some (fun uuid -> if uuid = "tag-1" then Some [ block ] else None);
      }
  in
  (let result =
     response_result (dispatch_json session "openNode" "{\"uuid\":\"block-1\"}")
   in
   let route = List.hd (json_items "nodeRoutes" result) in
   let related = List.hd (json_items "relatedBlocks" route) in
   check_eq (member "selectedPage" result) `Null;
   check_eq (member "uuid" route) (`String "block-1");
   check_eq (member "uuid" (member "page" route)) (`String "page-1");
   check_eq
     (json_items "zoomedBlockIds" (member "outlinerState" route))
     [ `String "block-1" ];
   check_eq (member "uuid" related) (`String "block-1");
   check_eq (List.length (json_items "breadcrumbs" related)) 1);
  (let result =
     response_result
       (dispatch_json session "outlinerEvent"
          "{\"type\":\"tapBlock\",\"uuid\":\"block-1\"}")
   in
   let route = List.hd (json_items "nodeRoutes" result) in
   check_eq (member "isOutlinerPatch" result) (`Bool false);
   check_eq
     (member "uuid" (member "editing" (member "outlinerState" route)))
     (`String "block-1"));
  (let result =
     response_result (dispatch_json session "openNode" "{\"uuid\":\"tag-1\"}")
   in
   let routes = json_items "nodeRoutes" result in
   let route = List.nth routes 1 in
   let related = List.hd (json_items "relatedBlocks" route) in
   check_eq (List.length routes) 2;
   check_eq (member "isTag" route) (`Bool true);
   check_eq (member "uuid" related) (`String "block-1");
   check_eq (List.length (json_items "breadcrumbs" related)) 1);
  let routes =
    json_items "nodeRoutes" (response_result (dispatch_json session "closeNode" ""))
  in
  check_eq (List.length routes) 1;
  check_eq (member "uuid" (List.hd routes)) (`String "block-1")

let search_block_reveals_page_and_zoom_has_ancestry () =
  let page : Model.entity_summary = { uuid = "page"; title = "Page" } in
  let parent = { (Model.local_block "parent" "Parent" "page" None 1) with
    Model.parent_id = Some "page"; order = Some "a0" } in
  let child = { parent with uuid = "child"; title = "Child"; parent_id = Some "parent" } in
  let sibling = { parent with uuid = "sibling"; title = "Sibling"; order = Some "a1" } in
  let session = Session.create_session { Session.default_options with
    graph_node_destination = Some (fun uuid -> Some (page, uuid <> "page"));
    graph_page_blocks = Some (fun _ -> Some [parent;child;sibling]) } in
  let route payload = List.hd (json_items "nodeRoutes"
    (response_result (dispatch_json session "openNode" payload))) in
  let zoom = route "{\"uuid\":\"child\"}" in
  check_eq ~msg:"zoom supplies ancestry without per-row breadcrumb loading"
    (List.map (member "uuid") (json_items "breadcrumbs" zoom))
    [`String "page"; `String "parent"];
  ignore (dispatch_json session "closeNode" "");
  let reveal = route "{\"uuid\":\"child\",\"reveal\":true}" in
  check_eq ~msg:"search opens the containing page" (member "uuid" reveal) (`String "page");
  check_eq ~msg:"search carries an exact scroll target" (member "scrollTarget" reveal) (`String "child");
  check_eq ~msg:"search includes siblings rather than zooming to the result"
    (List.map (fun row -> member "uuid" (member "block" row)) (json_items "outlinerRows" reveal))
    [`String "parent"; `String "child"; `String "sibling"]

let sidebar_tag_selection_projects_objects_and_linked_references () =
  let page : Model.entity_summary = { uuid = "tag-1"; title = "Task" } in
  let tagged =
    {
      (Model.local_block "task-1" "Do the thing" "page-1" None 1) with
      Model.parent_id = Some "page-1";
      order = Some "a0";
      sync_status = "synced";
    }
  in
  let linked = { tagged with uuid = "reference-1"; title = "Links Task" } in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_sidebar_pages =
          Some
            (fun () ->
              Some { Graph.favorites = [ page ]; recent_pages = [] });
        graph_page_blocks = Some (fun _ -> Some []);
        graph_node_is_tag = Some (fun uuid -> uuid = "tag-1");
        graph_tag_objects =
          Some (fun uuid -> if uuid = "tag-1" then Some [ tagged ] else None);
        graph_node_references =
          Some (fun uuid -> if uuid = "tag-1" then Some [ linked ] else None);
      }
  in
  let result =
    response_result (dispatch_json session "selectPage" "tag-1")
  in
  check_eq (member "selectedPageIsTag" result) (`Bool true);
  check_eq
    (member "uuid" (List.hd (json_items "relatedBlocks" result)))
    (`String "task-1");
  check_eq
    (member "uuid" (List.hd (json_items "linkedReferenceBlocks" result)))
    (`String "reference-1")

let favorite_blocks_select_the_root_subtree () =
  let conn = Ds.create_conn ~schema:Graph_read_test.schema () in
  let open Graph_read_test in
  transact conn [
    page "favorites" "$$$favorites" "Favorites" [];
    page "project" "project" "Project" [];
    entity "saved" "Saved block" [field "block/page" (Ds.Ref_to (Ds.Temp_id "project"));
      field "block/parent" (Ds.Ref_to (Ds.Temp_id "project"))];
    entity "child" "Child block" [field "block/page" (Ds.Ref_to (Ds.Temp_id "project"));
      field "block/parent" (Ds.Ref_to (Ds.Temp_id "saved"))];
    entity "sibling" "Sibling outside favorite" [field "block/page" (Ds.Ref_to (Ds.Temp_id "project"));
      field "block/parent" (Ds.Ref_to (Ds.Temp_id "project"))];
    entity "favorite-page" "" [field "block/page" (Ds.Ref_to (Ds.Temp_id "favorites"));
      field "block/link" (Ds.Ref_to (Ds.Temp_id "project"))];
    entity "favorite-block" "" [field "block/page" (Ds.Ref_to (Ds.Temp_id "favorites"));
      field "block/link" (Ds.Ref_to (Ds.Temp_id "saved"))]];
  let db = Ds.conn_db conn in
  let session = Session.create_session { Session.default_options with
    graph_sidebar_pages = Some (fun () -> Some (Graph.sidebar_pages plain db));
    graph_node_destination = Some (Graph.node_destination plain db);
    graph_page_blocks = Some (fun uuid -> Some (Graph.blocks_for_page plain db uuid)) } in
  let result = response_result (dispatch_json session "selectPage" "project") in
  check_eq ~msg:"favorite pages stay at the root"
    (member "uuid" (member "selectedPage" result)) (`String "project");
  check_eq (json_items "nodeRoutes" result) [];
  ignore (dispatch_json session "openNode" {|{"uuid":"child"}|});
  let selected = response_result (dispatch_json session "selectPage" "saved") in
  check_eq ~msg:"a favorite block replaces the root selection"
    (member "uuid" (member "selectedPage" selected)) (`String "saved");
  check_eq ~msg:"selecting a favorite clears the previous navigation stack"
    (json_items "nodeRoutes" selected) [];
  let rows = json_items "outlinerRows" selected in
  check_eq ~msg:"the root contains the favorite block and its children, not siblings"
    (List.map (fun row -> member "uuid" (member "block" row), member "depth" row) rows)
    [(`String "saved", `Int 0); (`String "child", `Int 1)];
  let editing = outliner_block_event session "tapBlock" "child" in
  check_eq ~msg:"editing a child still uses the favorite's owning page context"
    (member "uuid" (member "editing" (member "outlinerState" editing))) (`String "child");
  let page = response_result (dispatch_json session "selectPage" "project") in
  check_eq ~msg:"switching back to a page clears the favorite block zoom"
    (List.length (json_items "outlinerRows" page)) 3;
  check_eq (json_items "nodeRoutes" page) []

let sidebar_page_selection_projects_references_without_node_routes () =
  let page : Model.entity_summary = { uuid = "page-1"; title = "Page one" } in
  let reference =
    {
      (Model.local_block "reference-1" "Links Page one" "journal-1" None 1) with
      Model.parent_id = Some "journal-1";
      order = Some "a0";
      sync_status = "synced";
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_sidebar_pages =
          Some
            (fun () ->
              Some { Graph.favorites = [ page ]; recent_pages = [] });
        graph_page_blocks = Some (fun _ -> Some []);
        graph_node_references =
          Some (fun uuid -> if uuid = "page-1" then Some [ reference ] else None);
      }
  in
  let result =
    response_result (dispatch_json session "selectPage" "page-1")
  in
  check_eq (member "selectedPageIsTag" result) (`Bool false);
  check_eq
    (member "uuid" (List.hd (json_items "relatedBlocks" result)))
    (`String "reference-1");
  check (json_items "nodeRoutes" result = [])

let graph_assets_download_and_cache_binary_files () =
  let root = Filename.temp_file "logseq-asset-test" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () ->
    let rec remove path = if Sys.is_directory path then begin
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path in
    remove root) (fun () ->
    let page : Model.entity_summary = { uuid = "album-page"; title = "Album" } in
    let asset uuid parent = { (Model.local_block uuid uuid page.uuid None 1) with
      is_asset = true; asset_type = Some "png"; parent_id = Some parent } in
    let session = Session.create_session { Session.default_options with
      load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
      graph_sidebar_pages = Some (fun () -> Some { Graph.favorites = [page]; recent_pages = [] });
      graph_page_blocks = Some (fun _ -> Some [asset "image-uuid" "album"; asset "sibling" "album"; asset "unrelated" "other"]);
      resolve_asset_path = (fun path -> Filename.concat root path) } |> configure_plain_session in
    ignore (response_result (dispatch_json session "selectPage" page.uuid));
    let fields = ["uuid", `String "image-uuid"; "assetType", `String "image/png";
      "graphId", `String "plain-1"] in
    let dispatch action extra = dispatch_json session action (Json.to_string (`Assoc (fields @ extra))) in
    let prepared = response_result (dispatch "prepareAssetDownload" []) in
    let request = member "request" prepared in
    check_eq (member "url" request) (`String "http://127.0.0.1:8787/assets/plain-1/image-uuid.png");
    check_eq (member "token" request) (`String "access");
    let source = Filename.concat root "response" in
    let bytes = "\137PNG\000\255\001binary" in
    ignore (Asset_files.write_file source bytes);
    let cached = response_result (dispatch "cacheDownloadedAsset" ["path", `String source]) in
    let path = json_string (member "localPath" cached) in
    check_eq (Asset_files.read_file path) (Ok bytes);
    let reopened = response_result (dispatch "prepareAssetDownload" []) in
    check_eq (member "localPath" reopened) (`String path);
    check_eq (member "request" reopened) `Null;
    List.iter (fun uuid ->
      ignore (response_result (dispatch_json session "cacheDownloadedAsset"
        (Json.to_string (`Assoc ["uuid", `String uuid; "assetType", `String "png";
          "graphId", `String "plain-1"; "path", `String source]))))) ["sibling"; "unrelated"];
    let gallery = response_result (dispatch_json session "cachedImageGallery" "sibling") in
    check_eq ~msg:"preview contains only cached images from the same parent" (List.length (json_items "paths" gallery)) 2;
    check_eq (member "selectedIndex" gallery) (`Int 1);
    let stale = dispatch_json session "cacheDownloadedAsset"
      (Json.to_string (`Assoc ["graphId", `String "other"; "uuid", `String "image-uuid";
        "assetType", `String "png"; "path", `String source])) in
    check_eq (response_error_code stale) "graph_changed")

let mobile_page_references_are_deferred () =
  List.iter (fun is_tag ->
    let page : Model.entity_summary = { uuid = "deferred-page"; title = "Deferred" } in
    let body = Model.local_block "body" "Body" page.uuid None 1 in
    let reference = Model.local_block "reference" "Reference" "other" None 1 in
    let reads = ref 0 in
    let session = Session.create_session {
      Session.default_options with
      outliner_projection_limit = Some 32;
      graph_sidebar_pages = Some (fun () -> Some { Graph.favorites = [page]; recent_pages = [] });
      graph_node_destination = Some (fun _ -> Some (page, false));
      graph_node_is_tag = Some (fun _ -> is_tag);
      graph_page_blocks = Some (fun _ -> Some [body]);
      graph_tag_objects = Some (fun _ -> Some [body]);
      graph_node_references = Some (fun _ -> incr reads; Some [reference]);
    } in
    let first = response_result (dispatch_json session "selectPage" page.uuid) in
    check_eq ~msg:"first paint never queries references" !reads 0;
    check_eq (member "pendingReferenceUuid" first) (`String page.uuid);
    let loaded = response_result (dispatch_json session "loadPageReferences" page.uuid) in
    check_eq !reads 1;
    check_eq (member "pendingReferenceUuid" loaded) `Null;
    check_eq (member "isReferencePatch" loaded) (`Bool true);
    check_eq ~msg:"references never republish the page body" (member "outlinerRows" loaded) `Null;
    check_eq (member "uuid" (List.hd (json_items "referenceBlocks" loaded))) (`String reference.uuid);
    ignore (response_result (dispatch_json session "loadPageReferences" page.uuid));
    check_eq ~msg:"loaded references are reused" !reads 1;
    ignore (response_result (dispatch_json session "clearSelectedPage" ""));
    ignore (response_result (dispatch_json session "loadPageReferences" page.uuid));
    check_eq ~msg:"stale reference request cannot reopen a page" !reads 1;
    let opened = response_result (dispatch_json session "openNode" (Yojson.Basic.to_string (`Assoc ["uuid", `String page.uuid]))) in
    check_eq ~msg:"node routes share the reference cache" !reads 1;
    check_eq (List.length (json_items "nodeRoutes" opened)) 1
  ) [false; true]

let search_projects_page_context_and_clears_blank_queries () =
  let page : Model.entity_summary = { uuid = "page-1"; title = "Page one" } in
  let hit : Search.indexed_search_hit =
    {
      uuid = "block-1";
      title = "Search me";
      is_page = false;
      page = Some page;
      breadcrumbs = [ page ];
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_search =
          Some (fun query -> if query = "search" then [ hit ] else []);
      }
  in
  let result =
    response_result (dispatch_json session "searchNodes" "search")
  in
  let found = List.hd (json_items "searchResults" result) in
  check_eq (member "searchQuery" result) (`String "search");
  check_eq (member "uuid" found) (`String "block-1");
  check_eq (member "title" found) (`String "Search me");
  check_eq (member "isPage" found) (`Bool false);
  check_eq (member "uuid" (member "page" found)) (`String "page-1");
  check_eq (List.length (json_items "breadcrumbs" found)) 1;
  check_eq
    (member "title" (List.hd (json_items "breadcrumbs" found)))
    (`String "Page one");
  check
    (json_items "searchResults"
       (response_result (dispatch_json session "searchNodes" ""))
    = [])

let search_results_are_loaded_in_bounded_pages () =
  let hits = List.init 145 (fun i ->
    { Search.uuid = Printf.sprintf "hit-%03d" i; title = "Search";
      is_page = true; page = None; breadcrumbs = [] }) in
  let session = Session.create_session { Session.default_options with
    outliner_projection_limit = Some 32;
    graph_search = Some (fun _ -> hits) } in
  let first = response_result (dispatch_json session "searchNodes" "search") in
  check_eq ~msg:"the first response contains only one search page"
    (List.length (json_items "searchResults" first)) 20;
  check_eq (member "searchHasMore" first) (`Bool true);
  let next offset query = response_result (dispatch_json session "searchNodesPage"
    (Yojson.Basic.to_string (`Assoc ["query", `String query; "offset", `Int offset]))) in
  let second = next 20 "search" in
  check_eq (List.length (json_items "searchResults" second)) 20;
  check_eq (member "searchOffset" second) (`Int 20);
  check_eq (member "uuid" (List.hd (json_items "searchResults" second))) (`String "hit-020");
  check_eq ~msg:"late pages for an old query are ignored"
    (json_items "searchResults" (next 40 "older")) [];
  List.iter (fun offset -> ignore (next offset "search")) [40; 60; 80; 100];
  let last = next 120 "search" in
  check_eq (List.length (json_items "searchResults" last)) 20;
  let final = next 140 "search" in
  check_eq (List.length (json_items "searchResults" final)) 5;
  check_eq (member "searchHasMore" final) (`Bool false);
  check_eq (json_items "searchResults" (response_result (dispatch_json session "searchNodes" ""))) []

let node_navigation_resolves_projected_pages_and_blocks () =
  let page : Model.entity_summary =
    { uuid = "projected-page"; title = "Projected page" }
  in
  let block =
    {
      (Model.local_block "projected-block" "Projected block" "projected-page" None 1) with
      Model.parent_id = Some "projected-page";
      order = Some "a0";
      breadcrumbs = [ page ];
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some [ block ]);
        graph_page_blocks =
          Some
            (fun uuid ->
              Some (if uuid = "projected-page" then [ block ] else []));
        graph_node_destination = Some (fun _ -> None);
      }
  in
  ignore
    (Session.call session "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}");
  List.iter
    (fun (uuid, zoomed) ->
      let result =
        response_result
          (dispatch_json session "openNode"
             (Printf.sprintf "{\"uuid\":\"%s\"}" uuid))
      in
      let route = List.hd (json_items "nodeRoutes" result) in
      check_eq (member "uuid" route) (`String uuid);
      check_eq
        (member "uuid" (member "page" route))
        (`String "projected-page");
      check_eq
        (json_items "zoomedBlockIds" (member "outlinerState" route))
        zoomed;
      ignore (dispatch_json session "closeNode" ""))
    [ ("projected-page", []); ("projected-block", [ `String "projected-block" ]) ]

let offline_node_navigation_uses_pending_projection_and_journal_title () =
  let block =
    {
      (Model.local_block "cached-block" "Cached offline block" "journal/2026-08-15"
         None 1) with
      Model.parent_id = Some "journal/2026-08-15";
      order = Some "a0";
      journal = Some ("Aug 15th, 2026", 20260815);
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some [ block ]);
        graph_page_blocks =
          Some
            (fun uuid ->
              Some (if uuid = "journal/2026-08-15" then [ block ] else []));
        graph_node_destination = Some (fun _ -> None);
      }
  in
  let result =
    response_result
      (dispatch_json session "openNode" "{\"uuid\":\"cached-block\"}")
  in
  let route = List.hd (json_items "nodeRoutes" result) in
  check_eq (member "uuid" route) (`String "cached-block");
  check_eq
    (member "uuid" (member "page" route))
    (`String "journal/2026-08-15");
  check_eq
    (member "title" (member "page" route))
    (`String "Aug 15th, 2026");
  check_eq
    (json_items "zoomedBlockIds" (member "outlinerState" route))
    [ `String "cached-block" ];
  check_eq
    (member "uuid" (List.hd (json_items "blocks" route)))
    (`String "cached-block");
  check_eq
    (member "code"
       (member "error"
          (dispatch_json session "openNode" "{\"uuid\":\"missing-block\"}")))
    (`String "unknown_node")

let loading_older_journals_expands_core_owned_window () =
  let window = ref 7 in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_older_journals = Some (fun () -> window := !window + 7);
        has_older_journals = Some (fun () -> !window < 14);
      }
  in
  let initial =
    response_result
      (Json.from_string
         (Session.call session
            "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}"))
  in
  check_eq (member "hasOlderJournals" initial) (`Bool true);
  let expanded =
    response_result (dispatch_json session "loadOlderJournals" "")
  in
  check_eq (member "hasOlderJournals" expanded) (`Bool false)

let graph_import_forwards_payload_to_storage () =
  let imported = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        import_snapshot =
          Some (fun payload -> imported := !imported @ [ payload ]; Ok ());
      }
  in
  ignore (response_result (dispatch_json session "importSnapshot" "snapshot-payload"));
  check_eq !imported [ "snapshot-payload" ]

let opening_graph_reads_authoritative_projections_once () =
  let blocks_read = ref 0 in
  let sidebar_read = ref 0 in
  let block =
    {
      (Model.local_block "restored-journal-block" "Restored from the graph snapshot"
         "journal-page" None 1776000000000) with
      Model.parent_id = Some "journal-page";
      order = Some "a0";
      sync_status = "synced";
      journal = Some ("Aug 15th, 2026", 20260815);
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        open_graph = Some (fun _ -> Ok ());
        graph_blocks =
          Some
            (fun () ->
              incr blocks_read;
              Some [ block ]);
        graph_sidebar_pages =
          Some
            (fun () ->
              incr sidebar_read;
              Some { Graph.favorites = []; recent_pages = [] });
      }
  in
  let result =
    response_result (dispatch_json session "openGraph" "{}")
  in
  let blocks = json_items "blocks" result in
  check_eq !blocks_read 1;
  check_eq !sidebar_read 1;
  check_eq (List.length blocks) 1;
  check_eq
    (member "uuid" (List.hd blocks))
    (`String "restored-journal-block");
  check_eq (member "journalDay" (List.hd blocks)) (`Int 20260815)

let graph_storage_errors_preserve_codes_and_payload_priority () =
  let missing = Session.create_session Session.default_options in
  let calls = ref [] in
  let rejecting =
    Session.create_session
      {
        Session.default_options with
        import_snapshot =
          Some
            (fun payload ->
              calls := !calls @ [ payload ];
              Error "import rejected");
        open_graph =
          Some
            (fun payload ->
              calls := !calls @ [ payload ];
              Error "open rejected");
      }
  in
  List.iter
    (fun (action, unavailable, failed, message) ->
      let no_payload =
        Printf.sprintf
          "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"%s\"}}"
          action
      in
      let unavailable_error =
        member "error" (Json.from_string (Session.call missing no_payload))
      in
      let required_error =
        member "error" (Json.from_string (Session.call rejecting no_payload))
      in
      let service_error =
        member "error" (dispatch_json rejecting action "raw-payload")
      in
      check_eq (member "code" unavailable_error) (`String unavailable);
      check_eq (member "code" required_error) (`String "invalid_params");
      check_eq
        (member "message" required_error)
        (`String (action ^ " requires a JSON payload"));
      check_eq (member "code" service_error) (`String failed);
      check_eq (member "message" service_error) (`String message))
    [
      ( "importSnapshot",
        "snapshot_import_unavailable",
        "snapshot_import_failed",
        "import rejected" );
      ( "openGraph",
        "graph_open_unavailable",
        "graph_open_failed",
        "open rejected" );
    ];
  check_eq !calls [ "raw-payload"; "raw-payload" ]

let graph_storage_success_can_fail_projection_validation () =
  let stored = ref [] in
  let projected = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        import_snapshot =
          Some (fun payload -> stored := !stored @ [ payload ]; Ok ());
        open_graph =
          Some (fun payload -> stored := !stored @ [ payload ]; Ok ());
        model_for_graph =
          Some
            (fun graph_id ->
              projected := !projected @ [ graph_id ];
              Model.create None);
      }
  in
  List.iter
    (fun action ->
      let error = member "error" (dispatch_json session action "{}") in
      check_eq (member "code" error) (`String "graph_projection_failed");
      check_eq
        (member "message" error)
        (`String "graph storage payload requires graphId"))
    [ "importSnapshot"; "openGraph" ];
  check_eq !stored [ "{}"; "{}" ];
  check (!projected = [])

let sync_driver_session ?blocks () =
  let cursor = ref 10 in
  let applied = ref [] in
  let failure = ref None in
  let session = configure_plain_session (Session.create_session
    { Session.default_options with
      sync_cursor = Some (fun () -> Some !cursor);
      graph_blocks = Option.map (fun blocks () -> Some blocks) blocks;
      apply_sync_event = Some (fun body ->
        match !failure with
        | Some error -> Error error
        | None ->
          applied := body :: !applied;
          let frame = Json.from_string body in
          (match member "t" frame with `Int t -> cursor := t | _ -> ());
          Ok ()) }) in
  session, cursor, applied, failure

let begin_sync_transport session =
  response_result (dispatch_json session "beginSyncTransport" "{}")

let sync_transport response = member "syncTransport" response
let sync_commands response = json_items "commands" (sync_transport response)
let sync_command_kinds response = List.map (fun command -> json_string (member "type" command)) (sync_commands response)

let sync_event session generation kind extra =
  response_result (dispatch_json session "syncTransportEvent"
    (Json.to_string (`Assoc (["generation", `Int generation; "graphId", `String "plain-1"; "type", `String kind] @ extra))))

let sync_generation response = Json_util.to_int (member "generation" (sync_transport response))

let shared_sync_driver_owns_pull_protocol_and_notification_coalescing () =
  let session, cursor, applied, _ = sync_driver_session () in
  let begun = begin_sync_transport session in
  check_eq (sync_command_kinds begun) ["connect"];
  check_eq (member "url" (List.hd (sync_commands begun))) (`String "ws://127.0.0.1:8787/sync/plain-1");
  let generation = sync_generation begun in
  let opened = sync_event session generation "opened" [] in
  check_eq (sync_command_kinds opened) ["send"; "sync-pending"];
  check_eq (Json.from_string (json_string (member "body" (List.hd (sync_commands opened)))))
    (`Assoc ["type", `String "pull"; "since", `Int 10]);
  check_eq (sync_commands (sync_event session generation "opened" [])) [];
  List.iter (fun t ->
    let response = sync_event session generation "frame"
      ["body", `String (Json.to_string (`Assoc ["type", `String "changed"; "t", `Int t]))] in
    check_eq ~msg:"notifications coalesce behind the in-flight pull" (sync_commands response) []) [11; 12; 14];
  let pulled = sync_event session generation "frame" ["body", `String {|{"type":"pull/ok","t":12,"data":[]}|}] in
  check_eq (sync_command_kinds pulled) ["sync-pending"; "send"];
  check_eq !cursor 12;
  check_eq (List.length !applied) 1;
  check_eq (member "graphId" (Json.from_string (List.hd !applied))) (`String "plain-1");
  let caught_up = sync_event session generation "frame" ["body", `String {|{"type":"pull/ok","t":14,"data":[]}|}] in
  check_eq (sync_command_kinds caught_up) ["sync-pending"];
  let unchanged = sync_event session generation "frame" ["body", `String {|{"type":"changed","t":14}|}] in
  check_eq (sync_commands unchanged) []

let shared_sync_driver_scopes_events_and_controls_reconnect () =
  let session, _, applied, _ = sync_driver_session () in
  let generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session generation "opened" []);
  let failed = sync_event session generation "failed" ["message", `String "connection lost"] in
  check_eq (sync_command_kinds failed) ["close"; "retry"];
  check_eq (member "delayMs" (List.nth (sync_commands failed) 1)) (`Int 1000);
  let next = begin_sync_transport session in
  let next_generation = sync_generation next in
  check (next_generation > generation);
  check_eq (sync_commands (sync_event session generation "frame" ["body", `String {|{"type":"pull/ok","t":100}|}])) [];
  check_eq !applied [];
  ignore (sync_event session next_generation "opened" []);
  let failed = sync_event session next_generation "closed" [] in
  check_eq (member "delayMs" (List.nth (sync_commands failed) 1)) (`Int 2000);
  let generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session generation "opened" []);
  ignore (sync_event session generation "frame" ["body", `String {|{"type":"pull/ok","t":11}|}]);
  let failed = sync_event session generation "failed" [] in
  check_eq ~msg:"cursor progress resets reconnect backoff"
    (member "delayMs" (List.nth (sync_commands failed) 1)) (`Int 1000)

let shared_sync_driver_idle_recovery_resets_after_a_healthy_pull () =
  let session, cursor, _, _ = sync_driver_session () in
  for _ = 1 to 8 do
    let generation = sync_generation (begin_sync_transport session) in
    ignore (sync_event session generation "opened" []);
    ignore (sync_event session generation "frame"
      ["body", `String {|{"type":"pull/ok","t":10,"data":[]}|}]);
    check_eq !cursor 10;
    let failed = sync_event session generation "failed" ["message", `String "idle transport closed"] in
    check_eq ~msg:"healthy idle subscriptions reset retry delay without requiring graph edits"
      (member "delayMs" (List.nth (sync_commands failed) 1)) (`Int 1000)
  done

let shared_sync_driver_snapshot_recovery_is_explicit_and_edit_safe () =
  let session, _, _, failure = sync_driver_session ~blocks:[synced_block "editing" "Draft"] () in
  let generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session generation "opened" []);
  let editing = outliner_block_event session "tapBlock" "editing" in
  check_eq (member "uuid" (member "editing" (member "outlinerState" editing))) (`String "editing");
  failure := Some "sync schema mismatch";
  let reset = sync_event session generation "frame" ["body", `String {|{"type":"pull/ok","t":20}|}] in
  check_eq (sync_command_kinds reset) ["close"; "retry"];
  check_eq (member "snapshotRequired" (sync_transport reset)) (`Bool true);
  ignore (outliner_event session {|{"type":"cancelEditing"}|});
  let recover = begin_sync_transport session in
  check_eq (sync_command_kinds recover) ["snapshot"];
  failure := None;
  ignore (sync_event session (sync_generation recover) "snapshot-applied" []);
  check_eq (sync_command_kinds (begin_sync_transport session)) ["connect"]

let shared_sync_driver_reports_malformed_frames_and_cancels_without_retry () =
  let session, _, _, _ = sync_driver_session () in
  let generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session generation "opened" []);
  let malformed = sync_event session generation "frame" ["body", `String "not JSON"] in
  check_eq (sync_command_kinds malformed) ["close"; "retry"];
  let generation = sync_generation (begin_sync_transport session) in
  let cancelled = sync_event session generation "cancelled" [] in
  check_eq (sync_command_kinds cancelled) ["close"];
  check_eq (sync_commands (sync_event session generation "opened" [])) []

let shared_sync_driver_bounds_backoff_and_rejects_reconfigured_events () =
  let session, _, applied, _ = sync_driver_session () in
  List.iter (fun delay ->
    let generation = sync_generation (begin_sync_transport session) in
    ignore (sync_event session generation "opened" []);
    let failed = sync_event session generation "failed" [] in
    check_eq (member "delayMs" (List.nth (sync_commands failed) 1)) (`Int delay))
    [1000; 2000; 4000; 8000; 16000; 30000; 30000; 30000];
  let old_generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session old_generation "opened" []);
  let configured = response_result (dispatch_json session "configure"
    {|{"baseUrl":"https://example.com/api","graphId":"plain-1","token":"access"}|}) in
  check_eq ~msg:"changing the endpoint disconnects the old transport" (member "syncConnected" configured) (`Bool false);
  check_eq (sync_commands (sync_event session old_generation "frame"
    ["body", `String {|{"type":"pull/ok","t":99}|}])) [];
  check_eq !applied [];
  let next = begin_sync_transport session in
  check_eq (member "url" (List.hd (sync_commands next))) (`String "wss://example.com/sync/plain-1")

let clearing_authentication_invalidates_old_sync_transport () =
  let session, _, applied, _ = sync_driver_session () in
  let generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session generation "opened" []);
  let configured = response_result (dispatch_json session "configure"
    {|{"baseUrl":"http://127.0.0.1:8787","graphId":"plain-1","token":""}|}) in
  check_eq ~msg:"signing out disconnects sync without changing graphs"
    (member "syncConnected" configured) (`Bool false);
  check_eq (member "selectedGraphId" configured) (`String "plain-1");
  check_eq ~msg:"late frames from the previous account are ignored"
    (sync_commands (sync_event session generation "frame"
      ["body", `String {|{"type":"pull/ok","t":99}|}])) [];
  check_eq !applied []

let shared_sync_driver_handles_missing_cursor_and_network_changes () =
  let session = configure_plain_session (Session.create_session Session.default_options) in
  let initial = begin_sync_transport session in
  check_eq (sync_command_kinds initial) ["snapshot"];
  let session, _, _, _ = sync_driver_session () in
  let generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session generation "opened" []);
  let offline = sync_event session generation "network" ["available", `Bool false] in
  check_eq (sync_command_kinds offline) ["close"];
  let online = sync_event session generation "network" ["available", `Bool true] in
  check_eq (sync_command_kinds online) ["retry"];
  check_eq (member "delayMs" (List.hd (sync_commands online))) (`Int 0)

let retry_asset_session ?(encrypted = false) () =
  let staged = ref [] in
  let cleaned = ref [] in
  let session = Session.create_session
    { Session.default_options with
      load_graph_catalog = Some (fun () -> Some (if encrypted then encrypted_graph_catalog else plain_graph_catalog));
      sync_cursor = Some (fun () -> Some 41);
      journal_page_id = Some (fun _ -> Some "journal-page");
      graph_unlocked = Some (fun _ -> true);
      encrypt_title = Some (fun _ title -> Ok title);
      encrypt_asset_file = Some (fun _ _ -> Ok ("/tmp/encrypted-retry-asset", 2048));
      cleanup_file = (fun path -> cleaned := path :: !cleaned);
      stage_operation = Some (fun operation -> staged := operation :: !staged; Ok ());
      prepare_operation = Some prepare_operation } in
  if encrypted then begin
    ignore (configure_encrypted_session session);
    ignore (dispatch_json session "selectGraph" "encrypted-1")
  end else ignore (configure_plain_session session);
  ignore (dispatch_json session "addAsset"
    {|{"uuid":"retry-asset","title":"photo.png","now":2,"assetType":"png","assetSize":2048,"assetChecksum":"abc","localPath":"/documents/photo.png"}|});
  session, staged, cleaned

let pending_completion session request status body error =
  response_result (dispatch_json session "completePendingSync"
    (Json.to_string (`Assoc ["id", member "id" request; "status", status; "body", body; "error", error])))

let required_pending response = match member "pendingSyncRequest" response with
  | `Assoc _ as request -> request
  | _ -> failwith "expected an active pending request"

let shared_pending_retry_preserves_upload_and_bounds_attempts () =
  let session, staged, cleaned = retry_asset_session ~encrypted:true () in
  let request = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  List.iter (fun (status, error, delay) ->
    let result = pending_completion session request status `Null error in
    let retry = required_pending result in
    List.iter (fun key -> check_eq ~msg:("retry preserves " ^ key) (member key retry) (member key request))
      ["id"; "method"; "url"; "filePath"; "headers"; "body"];
    check_eq (member "delayMs" retry) (`Int delay);
    check_eq !cleaned [];
    check_eq (List.length !staged) 1)
    [`Null, `String "offline", 1000; `Int 429, `Null, 2000; `Int 503, `Null, 4000];
  let exhausted = pending_completion session request (`Int 503) (`String "unavailable") `Null in
  check_eq (member "pendingSyncRequest" exhausted) `Null;
  check_eq (member "pendingSyncError" exhausted) (`String "Sync server returned HTTP 503: unavailable");
  check_eq !cleaned ["/tmp/encrypted-retry-asset"];
  check_eq (List.length !staged) 1

let shared_pending_retry_keeps_semantic_transaction_identity () =
  let session, staged, _ = retry_asset_session () in
  let upload = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  let transaction = required_pending (pending_completion session upload (`Int 200) (`String "{}") `Null) in
  let retried = required_pending (pending_completion session transaction `Null `Null (`String "connection lost")) in
  check_eq (member "id" retried) (member "id" transaction);
  check_eq (member "body" retried) (member "body" transaction);
  check_eq (member "delayMs" retried) (`Int 1000);
  let accepted = pending_completion session retried (`Int 200) (`String {|{"acceptedT":42}|}) `Null in
  check_eq (member "pendingSyncRequest" accepted) `Null;
  check_eq (member "pendingSyncError" accepted) `Null;
  check (List.exists (fun operation -> operation.Ops.state = Ops.Accepted 42) !staged)

let shared_pending_retry_rejects_raw_upload_conflicts () =
  let session, staged, _ = retry_asset_session () in
  let upload = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  let conflict = pending_completion session upload (`Int 409)
    (`String {|{"error":"asset checksum already exists"}|}) `Null in
  check_eq (member "pendingSyncRequest" conflict) `Null;
  check_eq (member "pendingSyncError" conflict)
    (`String "Sync server returned HTTP 409: asset checksum already exists");
  check_eq (List.length !staged) 1

let shared_pending_retry_reports_transaction_rejection () =
  let session, staged, _ = retry_asset_session () in
  let upload = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  let transaction = required_pending (pending_completion session upload (`Int 200) (`String "{}") `Null) in
  let rejected = pending_completion session transaction (`Int 200)
    (`String {|{"type":"tx/reject","reason":"invalid data","error-detail":"should be a datetime"}|}) `Null in
  check_eq (member "pendingSyncRequest" rejected) `Null;
  check_eq (member "pendingSyncError" rejected)
    (`String "Sync server rejected the change: invalid data — should be a datetime");
  check (List.exists (fun operation -> operation.Ops.state = Ops.Conflicted "invalid data") !staged)

let shared_pending_error_summary_preserves_unicode () =
  let session, _, _ = retry_asset_session () in
  let upload = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  let transaction = required_pending (pending_completion session upload (`Int 200) (`String "{}") `Null) in
  let detail = String.make 4095 'x' ^ "中over" in
  let body = Json.to_string (`Assoc ["type", `String "tx/reject"; "reason", `String "invalid"; "error-detail", `String detail]) in
  let rejected = pending_completion session transaction (`Int 200) (`String body) `Null in
  check_eq (member "pendingSyncError" rejected)
    (`String ("Sync server rejected the change: invalid — " ^ String.make 4095 'x' ^ "中"))

let shared_pending_retry_cancellation_cleans_once_and_ignores_late_results () =
  let session, staged, cleaned = retry_asset_session ~encrypted:true () in
  let upload = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  ignore (pending_completion session upload `Null `Null (`String "offline"));
  ignore (response_result (dispatch_json session "cancelPendingSync" ""));
  let late = pending_completion session upload (`Int 200) (`String "{}") `Null in
  check_eq (member "pendingSyncRequest" late) `Null;
  check_eq !cleaned ["/tmp/encrypted-retry-asset"];
  check_eq (List.length !staged) 1

let shared_pending_retry_graph_changes_discard_old_transport () =
  let session, staged, cleaned = retry_asset_session ~encrypted:true () in
  let upload = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  let changed = response_result (dispatch_json session "configure"
    {|{"baseUrl":"http://other-server","graphId":"other-graph","token":"access"}|}) in
  check_eq (member "pendingSyncRequest" changed) `Null;
  check_eq !cleaned ["/tmp/encrypted-retry-asset"];
  ignore (pending_completion session upload (`Int 200) (`String "{}") `Null);
  check_eq (List.length !staged) 1

let clearing_authentication_cancels_requests_without_dropping_local_edits () =
  let session, staged, cleaned = retry_asset_session ~encrypted:true () in
  let upload = required_pending (response_result (dispatch_json session "beginPendingSync" "")) in
  let changed = response_result (dispatch_json session "configure"
    {|{"baseUrl":"http://127.0.0.1:8787","graphId":"encrypted-1","token":""}|}) in
  check_eq ~msg:"logout cancels a request carrying the previous token"
    (member "pendingSyncRequest" changed) `Null;
  check_eq ~msg:"temporary encrypted upload data is cleaned" !cleaned ["/tmp/encrypted-retry-asset"];
  check_eq ~msg:"local changes stay queued for a future login" (List.length !staged) 1;
  ignore (pending_completion session upload (`Int 200) (`String "{}") `Null);
  check_eq ~msg:"late upload completion cannot consume local edits" (List.length !staged) 1

let websocket_lifecycle_applies_events_exactly_once () =
  let applied = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        apply_sync_event =
          Some (fun payload -> applied := !applied @ [ payload ]; Ok ());
      }
  in
  ignore (response_result (dispatch_json session "startWebSocket" ""));
  ignore (response_result (dispatch_json session "applySyncEvent" "wire-event"));
  ignore (response_result (dispatch_json session "stopWebSocket" ""));
  check_eq !applied [ "wire-event" ]

let websocket_self_echo_clears_local_pending_capture () =
  let authoritative = ref [] in
  let block =
    {
      (Model.local_block "local-self-echo" "Synced capture" "journal/2026-08-15"
         None 1776000000000) with
      Model.sync_status = "synced";
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some !authoritative);
        apply_sync_event =
          Some
            (fun _ ->
              authoritative := [ block ];
              Ok ());
      }
  in
  ignore
    (dispatch_json session "send"
       "{\"text\":\"Synced capture\",\"uuid\":\"local-self-echo\",\"now\":1776000000000}");
  check_eq
    (List.length (Model.pending_blocks (Session.state session).model))
    1;
  ignore (response_result (dispatch_json session "applySyncEvent" "self-echo"));
  check (Model.pending_blocks (Session.state session).model = [])

let authoritative_assets_retain_cached_local_file_path () =
  let authoritative = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some !authoritative);
      }
  in
  ignore
    (dispatch_json session "addAsset"
       "{\"uuid\":\"synced-asset\",\"title\":\"photo.png\",\"now\":1776000000001,\"assetType\":\"png\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.png\"}");
  ignore
    (Model.mark_block_synced (Session.state session).model "synced-asset");
  authoritative :=
    [
      {
        (Model.local_block "synced-asset" "photo.png" "journal/2026-08-15" None
           1776000000001) with
        Model.sync_status = "synced";
        journal = Some ("Aug 15th, 2026", 20260815);
      };
    ];
  let blocks =
    json_items "blocks" (response_result (dispatch_json session "clearRelated" ""))
  in
  check_eq (List.length blocks) 1;
  check_eq
    (member "localPath" (List.hd blocks))
    (`String "/documents/photo.png")

let task_status_updates_preserve_custom_icon_color () =
  let session = Session.create_session Session.default_options in
  ignore
    (dispatch_json session "sendTask"
       "{\"text\":\"Follow up\",\"uuid\":\"task-status-local\",\"now\":1776000000000,\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\"}}");
  let result =
    response_result
      (dispatch_json session "updateBlockStatus"
         "{\"uuid\":\"task-status-local\",\"status\":{\"uuid\":\"custom-waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"iconType\":\"tabler-icon\",\"iconId\":\"clock\",\"iconColor\":\"#7c3aed\"}}")
  in
  let blocks = json_items "blocks" result in
  let status = member "status" (List.hd blocks) in
  check_eq (List.length blocks) 1;
  check_eq (member "uuid" status) (`String "custom-waiting");
  check_eq (member "color" (member "icon" status)) (`String "#7c3aed")

let authoritative_sync_preserves_editor_and_updates_visible_remote_block () =
  let editing =
    {
      (Model.local_block "editing-sync" "Local draft" "page" (Some "page") 1) with
      Model.order = Some "a0";
      sync_status = "synced";
    }
  in
  let remote = { editing with uuid = "remote-sync"; title = "Before" } in
  let authoritative = ref [ editing; remote ] in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some !authoritative);
        apply_sync_event =
          Some
            (fun _ ->
              authoritative := [ editing; { remote with title = "After" } ];
              Ok ());
      }
  in
  ignore
    (dispatch_json session "outlinerEvent"
       "{\"type\":\"tapBlock\",\"uuid\":\"editing-sync\"}");
  let result =
    response_result (dispatch_json session "applySyncEvent" "remote-change")
  in
  let active_editor = member "editing" (member "outlinerState" result) in
  check_eq (member "uuid" active_editor) (`String "editing-sync");
  check
    (List.exists
       (fun row ->
         let block = member "block" row in
         member "uuid" block = `String "remote-sync"
         && member "title" block = `String "After")
       (json_items "outlinerRows" result))

let journal_pagination_preserves_editor_selection_and_zoom () =
  let parent =
    {
      (Model.local_block "parent-window" "Parent" "page" (Some "page") 1) with
      Model.order = Some "a0";
      sync_status = "synced";
    }
  in
  let child =
    { parent with uuid = "child-window"; title = "Child"; parent_id = Some "parent-window" }
  in
  List.iter
    (fun event ->
      let session =
        Session.create_session
          {
            Session.default_options with
            graph_blocks = Some (fun () -> Some [ parent; child ]);
            load_older_journals = Some (fun () -> ());
            has_older_journals = Some (fun () -> true);
          }
      in
      let before =
        response_result (dispatch_json session "outlinerEvent" event)
      in
      let after =
        response_result (dispatch_json session "loadOlderJournals" "")
      in
      check_eq
        (member "outlinerState" before)
        (member "outlinerState" after))
    [
      "{\"type\":\"tapBlock\",\"uuid\":\"child-window\"}";
      "{\"type\":\"longPressBlock\",\"uuid\":\"child-window\"}";
      "{\"type\":\"zoomIn\",\"uuid\":\"parent-window\"}";
    ]

let outliner_editing_and_autocomplete_remain_owned_by_core () =
  let block =
    {
      (Model.local_block "editable" "Hello" "page" (Some "page") 1) with
      Model.order = Some "a0";
      sync_status = "synced";
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some [ block ]);
      }
  in
  let tapped =
    response_result
      (dispatch_json session "outlinerEvent"
         "{\"type\":\"tapBlock\",\"uuid\":\"editable\"}")
  in
  let editing = member "editing" (member "outlinerState" tapped) in
  check_eq (member "uuid" editing) (`String "editable");
  check_eq (member "title" editing) (`String "Hello");
  check (json_items "outlinerCommands" tapped = []);
  let changed =
    response_result
      (dispatch_json session "outlinerEvent"
         "{\"type\":\"textChanged\",\"title\":\"Hello [[Pro\",\"caretUTF16Offset\":11}")
  in
  let state = member "outlinerState" changed in
  let autocomplete = member "autocomplete" state in
  check_eq
    (member "title" (member "editing" state))
    (`String "Hello [[Pro");
  check_eq (member "kind" autocomplete) (`String "node");
  check_eq (member "query" autocomplete) (`String "Pro")

let tag_autocomplete_candidates_use_canonical_graph_identity () =
  let tag_page : Model.entity_summary = { uuid = "tag-uuid"; title = "Project" } in
  let block =
    {
      (Model.local_block "tag-editable" "Hello" "page" (Some "page") 1) with
      Model.order = Some "a0";
      sync_status = "synced";
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some [ block ]);
        graph_tag_pages = Some (fun () -> Some [ tag_page ]);
      }
  in
  ignore
    (response_result
       (dispatch_json session "outlinerEvent"
          "{\"type\":\"tapBlock\",\"uuid\":\"tag-editable\"}"));
  let result =
    response_result
      (dispatch_json session "outlinerEvent" "{\"type\":\"toolbar\",\"action\":\"tag\"}")
  in
  let candidates = json_items "outlinerAutocompleteCandidates" result in
  check_eq (List.length candidates) 1;
  check_eq (member "label" (List.hd candidates)) (`String "Project");
  check_eq (member "value" (List.hd candidates)) (`String "tag-uuid")

let page_autocomplete_searches_beyond_sidebar_and_current_page () =
  Search_index_test.with_index (fun index ->
    let conn = Search_index_test.seeded_conn () in
    let chinese_uuid = "018f7850-0000-7da0-8b3f-6dbb64aa4ec7" in
    ignore (Ds.transact_conn conn [
      Search_index_test.add 7 "block/uuid" (Ds.Uuid chinese_uuid);
      Search_index_test.add 7 "block/name" (Ds.String "页面搜索");
      Search_index_test.add 7 "block/title" (Ds.String "页面搜索")]);
    let db = Ds.conn_db conn in
    Search.refresh index db;
    let searches = ref [] in
    let staged = ref [] in
    let session = configure_plain_session (Session.create_session {
      Session.default_options with
      graph_blocks = Some (fun () -> Some [synced_block "editing" "Draft"]);
      graph_search = Some (fun query -> searches := query :: !searches;
        Search.search_hits 100 index db query);
      sync_cursor = Some (fun () -> Some 42);
      stage_operation = Some (fun operation -> staged := operation :: !staged; Ok ());
      prepare_operation = Some prepare_operation;
    }) in
    ignore (outliner_block_event session "tapBlock" "editing");
    let query text =
      let title = "Draft [[" ^ text ^ "]]" in
      outliner_event session (Json.to_string (`Assoc [
        "type", `String "textChanged"; "title", `String title;
        "caretUTF16Offset", `Int (Outliner.utf16_length title - 2)])) in
    ignore (query "");
    check_eq ~msg:"opening an empty reference keeps graph scans off the typing path" !searches [];
    List.iter (fun (text, uuid, label) ->
      let result = query text in
      let candidates = json_items "outlinerAutocompleteCandidates" result in
      check ~msg:("existing page outside sidebar is found for " ^ text)
        (List.exists (fun candidate -> member "value" candidate = `String uuid) candidates);
      let completed = outliner_event session (Json.to_string (`Assoc [
        "type", `String "chooseAutocomplete"; "value", `String uuid])) in
      check_eq ~msg:"completion inserts the page title, not its UUID"
        (member "title" (member "editing" (member "outlinerState" completed)))
        (`String ("Draft [[" ^ label ^ "]]"));
      check_eq ~msg:"selecting an existing page never creates a duplicate" !staged [])
      ["MOV", Search_index_test.page_uuid, "Movies";
       "页面", chinese_uuid, "页面搜索"];
    let missing = json_items "outlinerAutocompleteCandidates" (query "No such page") in
    check_eq (member "label" (List.hd missing)) (`String "New page: No such page");
    let hidden = json_items "outlinerAutocompleteCandidates" (query "Secret movies") in
    check ~msg:"hidden pages are excluded from reference search"
      (not (List.exists (fun candidate -> member "value" candidate = `String Search_index_test.hidden_uuid) hidden)))

let block_reference_completion_saves_the_selected_uuid () =
  Search_index_test.with_index (fun index ->
    let conn = Search_index_test.seeded_conn () in
    let choices = [
      70, "018f7850-0000-7da0-8b3f-6dbb64aa4ed1", "Distinct block";
      71, "018f7850-0000-7da0-8b3f-6dbb64aa4ed2", "Same title";
      72, "018f7850-0000-7da0-8b3f-6dbb64aa4ed3", "Same title"] in
    List.iter (fun (eid, uuid, title) ->
      ignore (Ds.transact_conn conn [
        Search_index_test.add eid "block/uuid" (Ds.Uuid uuid);
        Search_index_test.add eid "block/title" (Ds.String title);
        Search_index_test.add eid "block/page" (Ds.Ref 1);
        Search_index_test.add eid "block/parent" (Ds.Ref 1)])) choices;
    let db = Ds.conn_db conn in
    Search.refresh index db;
    List.iter (fun (_, uuid, title) ->
      let staged = ref [] in
      let session = configure_plain_session (Session.create_session {
        Session.default_options with
        graph_blocks = Some (fun () -> Some [synced_block "editing" "Draft"]);
        graph_search = Some (fun query -> Search.search_hits 100 index db query);
        graph_node_destination = Some (Graph.node_destination (fun value -> Ok value) db);
        graph_normalize_titles = Some (Graph.normalize_titles_creating_tags db (fun () -> "unexpected-tag"));
        sync_cursor = Some (fun () -> Some 42);
        stage_operation = Some (fun operation -> staged := operation :: !staged; Ok ());
        prepare_operation = Some prepare_operation }) in
      ignore (outliner_block_event session "tapBlock" "editing");
      let draft = "Draft [[" ^ title ^ "]]" in
      ignore (outliner_event session (Json.to_string (`Assoc ["type", `String "textChanged";
        "title", `String draft; "caretUTF16Offset", `Int (Outliner.utf16_length draft - 2)])));
      let completed = outliner_event session (Json.to_string (`Assoc ["type", `String "chooseAutocomplete";
        "value", `String uuid])) in
      let expected = "Draft [[" ^ uuid ^ "]]" in
      let editing = member "editing" (member "outlinerState" completed) in
      check_eq ~msg:"block references use UUID syntax even outside the current page projection"
        (member "title" editing) (`String expected);
      check_eq ~msg:"confirming a block reference places its caret after the closing brackets"
        (member "caretUTF16Offset" editing) (`Int (Outliner.utf16_length expected));
      ignore (outliner_event session {|{"type":"saveEditing"}|});
      check_eq ~msg:"the saved operation preserves exactly the chosen block, including duplicate titles"
        (List.filter_map (fun operation -> match operation.Ops.intent with
          | Ops.Save_title change -> Some change.title | _ -> None) !staged) [expected]) choices)

let websocket_errors_distinguish_snapshot_recovery_from_apply_failures () =
  List.iter
    (fun (message, code) ->
      let session =
        Session.create_session
          {
            Session.default_options with
            apply_sync_event = Some (fun _ -> Error message);
          }
      in
      let error =
        member "error" (dispatch_json session "applySyncEvent" "remote-change")
      in
      check_eq (member "code" error) (`String code);
      check_eq (member "message" error) (`String message))
    [
      ("sync schema mismatch", "snapshot_required");
      ("snapshot required: stale cursor", "snapshot_required");
      ("snapshot required:", "snapshot_required");
      ("snapshot required", "websocket_apply_failed");
      (" sync schema mismatch", "websocket_apply_failed");
      ("offline", "websocket_apply_failed");
    ];
  let wire =
    "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"applySyncEvent\"}}"
  in
  let unavailable = Session.create_session Session.default_options in
  let available =
    Session.create_session
      {
        Session.default_options with
        apply_sync_event = Some (fun _ -> Ok ());
      }
  in
  check_eq
    (member "code"
       (member "error" (Json.from_string (Session.call unavailable wire))))
    (`String "websocket_unavailable");
  check_eq
    (member "code"
       (member "error" (Json.from_string (Session.call available wire))))
    (`String "invalid_params")

let pending_sync_rejects_stale_completions_and_preserves_failed_block () =
  let session = plain_session () in
  ignore
    (dispatch_json session "send"
       "{\"text\":\"Retry later\",\"uuid\":\"failed-async\",\"now\":1776000000000}");
  ignore (dispatch_json session "beginPendingSync" "");
  check
    (not
       (Json_util.to_bool
          (member "ok"
             (dispatch_json session "completePendingSync"
                "{\"id\":99,\"status\":201,\"body\":\"{}\",\"error\":null}"))));
  for _ = 0 to 3 do
    ignore (dispatch_json session "completePendingSync"
      {|{"id":1,"status":null,"body":null,"error":"offline"}|})
  done;
  match Model.read_block (Session.state session).model "failed-async" with
  | Some block -> check_eq block.Model.sync_status "failed"
  | None -> check false

let pending_sync_completions_after_cancellation_are_idempotent () =
  let session = plain_session () in
  ignore
    (dispatch_json session "send"
       "{\"text\":\"Canceled request\",\"uuid\":\"canceled-pending\",\"now\":1776000000000}");
  ignore (dispatch_json session "beginPendingSync" "");
  ignore (dispatch_json session "cancelPendingSync" "");
  check
    (Json_util.to_bool
       (member "ok"
          (dispatch_json session "completePendingSync"
             "{\"id\":1,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"canceled-pending\\\"}\",\"error\":null}")))

let pending_sync_duplicate_completions_are_idempotent () =
  let session = plain_session () in
  let completion =
    "{\"id\":1,\"status\":201,\"body\":\"{\\\"uuid\\\":\\\"duplicate-pending\\\"}\",\"error\":null}"
  in
  ignore
    (dispatch_json session "send"
       "{\"text\":\"Duplicate completion\",\"uuid\":\"duplicate-pending\",\"now\":1776000000000}");
  ignore (dispatch_json session "beginPendingSync" "");
  ignore (dispatch_json session "completePendingSync" completion);
  check
    (Json_util.to_bool
       (member "ok" (dispatch_json session "completePendingSync" completion)))

let task_update_pump_submits_title_before_status () =
  let status : Model.status =
    {
      uuid = "todo";
      title = "Todo";
      ident = None;
      icon_type = None;
      icon_id = None;
      icon_color = None;
    }
  in
  let block =
    {
      (Model.local_block "remote-task" "Old title" "journal-page" None
         1776000000000) with
      Model.sync_status = "synced";
      status = Some status;
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
        graph_blocks = Some (fun () -> Some [ block ]);
      }
  in
  ignore
    (dispatch_json session "configure"
       "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}");
  Model.upsert_blocks (Session.state session).model [ block ] block.updated_at;
  ignore
    (dispatch_json session "updateBlock"
       "{\"uuid\":\"remote-task\",\"title\":\"New title\",\"status\":{\"uuid\":\"doing\",\"title\":\"Doing\"}}");
  (match pending_request (dispatch_json session "beginPendingSync" "") with
   | Some request ->
     check_eq (json_string (member "method" request)) "PATCH"
   | None -> check false);
  (match
     pending_request
       (dispatch_json session "completePendingSync"
          "{\"id\":1,\"status\":200,\"body\":\"{}\",\"error\":null}")
   with
   | Some request ->
     check_eq (json_string (member "method" request)) "PUT";
     check
       (String.ends_with ~suffix:"/properties/Status"
          (json_string (member "url" request)))
   | None -> check false);
  check
    (pending_request
       (dispatch_json session "completePendingSync"
          "{\"id\":2,\"status\":200,\"body\":\"{}\",\"error\":null}")
    = None);
  match Model.read_block (Session.state session).model "remote-task" with
  | Some updated -> check_eq updated.Model.sync_status "submitted"
  | None -> check false

let encrypted_graph_creation_provisions_uploads_and_cleans_up_in_order () =
  let created = ref false in
  let provisioned = ref None in
  let events = ref [] in
  let uploaded_path = ref None in
  let ends_with s suffix = String.ends_with ~suffix s in
  let session =
    Session.create_session
      {
        Session.default_options with
        send =
          (fun request ->
            if
              request.Api.method_ = "POST" && ends_with request.url "/graphs"
            then (
              events := !events @ [ "create" ];
              created := true;
              Ok (Api.response 201 "{\"graph-id\":\"new-private\"}"))
            else if ends_with request.url "/graphs" then (
              events := !events @ [ "discover" ];
              Ok
                (Api.response 200
                   (if !created then
                      "{\"graphs\":[{\"graph-id\":\"new-private\",\"graph-name\":\"Private notes\",\"schema-version\":\"65.33\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":true}]}"
                    else "{\"graphs\":[]}")))
            else Error ("unexpected request: " ^ request.url));
        provision_graph_key =
          Some
            (fun config ->
              events := !events @ [ "provision" ];
              provisioned := Some config.Api.graph_id;
              Ok ());
        encrypt_title =
          Some (fun _graph_id value -> Ok ("encrypted:" ^ value));
        upload_file =
          (fun upload ->
            events := !events @ [ "upload" ];
            uploaded_path := Some upload.Api.file_path;
            check (Sys.file_exists upload.file_path);
            check (String.contains upload.request.url '?');
            check
              (ends_with upload.request.url "checksum=0000000000000000");
            check_eq upload.content_type "application/transit+json";
            Ok (Api.response 200 "{\"ok\":true,\"count\":8}"));
      }
  in
  ignore
    (dispatch_json session "configure"
       "{\"baseUrl\":\"https://api.example\",\"graphId\":\"\",\"token\":\"access\"}");
  check
    (Json_util.to_bool
       (member "ok"
          (dispatch_json session "createSyncGraph"
             "{\"name\":\"Private notes\",\"isEncrypted\":true}")));
  check_eq !provisioned (Some "new-private");
  check_eq !events [ "create"; "provision"; "upload"; "discover" ];
  match !uploaded_path with
  | Some path -> check (not (Sys.file_exists path))
  | None -> check false

let journal_calendar_opens_existing_days_and_creates_missing_days () =
  let pages = Hashtbl.create 4 in
  Hashtbl.add pages 20261019 "existing-journal";
  let staged = ref [] in
  let session = Session.create_session { Session.default_options with
    load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
    sync_cursor = Some (fun () -> Some 91);
    journal_page_id = Some (Hashtbl.find_opt pages);
    stage_operation = Some (fun operation ->
      staged := operation :: !staged;
      (match operation.Ops.intent with
       | Ops.Create_journal journal -> Hashtbl.replace pages journal.journal_day journal.page_uuid
       | _ -> ()); Ok ());
    prepare_operation = Some prepare_operation } in
  ignore (dispatch_json session "configure"
    "{\"baseUrl\":\"https://example.com\",\"graphId\":\"plain-1\",\"token\":\"access\"}");
  let existing = dispatch_json session "ensureJournal" "20261019" in
  check ~msg:"the calendar can resolve an existing journal" (Json_util.to_bool (member "ok" existing));
  check_eq (json_string (member "uuid" (member "result" existing))) "existing-journal";
  check_eq ~msg:"opening an existing journal does not write a transaction" !staged [];
  let created = dispatch_json session "ensureJournal" "20261020" in
  check (Json_util.to_bool (member "ok" created));
  let uuid = json_string (member "uuid" (member "result" created)) in
  (match !staged with
   | [operation] -> (match operation.Ops.intent with
     | Ops.Create_journal journal ->
       check_eq journal.journal_day 20261020;
       check_eq journal.page_uuid uuid;
       check_eq ~msg:"new journals have the standard date title" journal.title "Oct 20th, 2026"
     | _ -> check false)
   | _ -> check false);
  let again = dispatch_json session "ensureJournal" "20261020" in
  check_eq (json_string (member "uuid" (member "result" again))) uuid;
  check_eq ~msg:"repeated selection never duplicates the journal" (List.length !staged) 1;
  List.iter (fun day ->
    check ~msg:"calendar rejects invalid dates without writing" (not (Json_util.to_bool
      (member "ok" (dispatch_json session "ensureJournal" day)))))
    ["20260230"; "20261301"; "0"; "invalid"];
  check_eq (List.length !staged) 1

let semantic_capture_pump_never_calls_blocking_transport () =
  let legacy_send_count = ref 0 in
  let staged = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
        sync_cursor = Some (fun () -> Some 91);
        journal_page_id = Some (fun _day -> Some "journal-page");
        stage_operation =
          Some
            (fun operation ->
              staged :=
                operation
                :: List.filter
                     (fun (op : Ops.pending_operation) ->
                       op.operation_id <> operation.Ops.operation_id)
                     !staged;
              Ok ());
        prepare_operation = Some prepare_operation;
        pending_operations = Some (fun () -> List.rev !staged);
        send =
          (fun _request ->
            incr legacy_send_count;
            failwith "asynchronous pending pump called the blocking transport");
      }
  in
  ignore
    (dispatch_json session "configure"
       "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}");
  let response =
    dispatch_json session "send"
      "{\"text\":\"First title\",\"uuid\":\"async-local\",\"now\":1776000000000}"
  in
  check
    (Json_util.to_bool
       (member "hasPendingSemanticOperations" (member "result" response)));
  (match pending_request (dispatch_json session "beginPendingSync" "") with
   | Some request ->
     check_eq (json_string (member "method" request)) "WS";
     check_eq
       (json_string (member "url" request))
       "ws://127.0.0.1:8787/sync/plain-1";
     check_eq (Json_util.to_int (member "id" request)) 1
   | None -> check false);
  check_eq !legacy_send_count 0;
  check
    (pending_request
       (dispatch_json session "completePendingSync"
          "{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":92}\",\"error\":null}")
    = None)

let encrypted_task_stages_journal_before_status_and_drains_both_requests () =
  let staged = ref [] in
  let cursor = ref 91 in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some encrypted_graph_catalog);
        graph_unlocked = Some (fun _graph_id -> true);
        sync_cursor = Some (fun () -> Some !cursor);
        journal_page_id = Some (fun _day -> None);
        stage_operation =
          Some (fun operation -> staged := !staged @ [ operation ]; Ok ());
        prepare_operation = Some prepare_operation;
      }
  in
  ignore (configure_encrypted_session session);
  ignore (dispatch_json session "selectGraph" "encrypted-1");
  ignore
    (dispatch_json session "sendTask"
       "{\"text\":\"Secret task\",\"uuid\":\"encrypted-async\",\"now\":1776000000000,\"status\":{\"uuid\":\"todo\",\"title\":\"Todo\"}}");
  check_eq (List.length !staged) 2;
  (match (List.nth !staged 0).Ops.intent with
   | Ops.Create_journal journal ->
     check_eq journal.block_uuid "encrypted-async";
     check_eq journal.block_title "Secret task";
     check_eq journal.title (Rpc_wire.journal_day_title journal.journal_day)
   | _ -> check false);
  (match (List.nth !staged 1).Ops.intent with
   | Ops.Set_property property ->
     check_eq property.uuid "encrypted-async";
     check_eq property.attr "logseq.property/status"
   | _ -> check false);
  let begin_response = dispatch_json session "beginPendingSync" "" in
  cursor := 92;
  let complete_response =
    dispatch_json session "completePendingSync"
      "{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":92}\",\"error\":null}"
  in
  List.iter
    (fun response ->
      match pending_request response with
      | Some request ->
        check_eq
          (json_string (member "url" request))
          "ws://127.0.0.1:8787/sync/encrypted-1"
      | None -> check false)
    [ begin_response; complete_response ];
  cursor := 93;
  check
    (pending_request
       (dispatch_json session "completePendingSync"
          "{\"id\":2,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":93}\",\"error\":null}")
    = None)

let graph_creation_stops_after_initial_upload_failure () =
  let discovered = ref false in
  let ends_with s suffix = String.ends_with ~suffix s in
  let session =
    Session.create_session
      {
        Session.default_options with
        send =
          (fun request ->
            if request.method_ = "POST" && ends_with request.url "/graphs"
            then Ok (Api.response 201 "{\"graph-id\":\"upload-fails\"}")
            else if ends_with request.url "/graphs" then (
              discovered := true;
              Ok (Api.response 200 "{\"graphs\":[]}"))
            else Error ("unexpected request: " ^ request.url));
        upload_file =
          (fun _upload -> Error "offline during initial snapshot upload");
      }
  in
  ignore
    (Session.call session
       "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"https://api.example\\\",\\\"graphId\\\":\\\"\\\",\\\"token\\\":\\\"access\\\"}\"}}");
  let response =
    Json.from_string
      (Session.call session
         "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"createSyncGraph\",\"payload\":\"{\\\"name\\\":\\\"Incomplete\\\",\\\"isEncrypted\\\":false}\"}}")
  in
  check (not (Json_util.to_bool (member "ok" response)));
  check_eq
    (json_string (member "code" (member "error" response)))
    "graph_initial_upload_failed";
  check (not !discovered)

let autosave_emits_bounded_patches_and_advances_expected_title () =
  let staged = ref [] in
  let projected = ref [ synced_block "bounded-save" "Before" ] in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 91);
           graph_blocks = Some (fun () -> Some !projected);
           stage_operation =
             Some
               (fun operation ->
                 staged := !staged @ [ operation ];
                 (match operation.Ops.intent with
                  | Ops.Save_title change ->
                    projected :=
                      List.map
                        (fun (block : Model.block) ->
                          if block.uuid = change.uuid then
                            { block with title = change.title }
                          else block)
                        !projected
                  | _ -> ignore !projected);
                 Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore (outliner_event session "{\"type\":\"tapBlock\",\"uuid\":\"bounded-save\"}");
  ignore
    (outliner_event session
       "{\"type\":\"textChanged\",\"title\":\"After\",\"caretUTF16Offset\":5}");
  (let saved = outliner_event session "{\"type\":\"saveEditing\"}" in
   let blocks = json_items "blocks" saved in
   let editing = member "editing" (member "outlinerState" saved) in
   check_eq (member "isOutlinerPatch" saved) (`Bool true);
   check_eq (List.length blocks) 1;
   check_eq (member "title" (List.hd blocks)) (`String "After");
   check (json_items "outlinerRows" saved = []);
   check (json_items "outlinerRowSplices" saved = []);
   check_eq (member "uuid" editing) (`String "bounded-save"));
  check_eq (List.length !staged) 1;
  ignore (outliner_event session "{\"type\":\"saveEditing\"}");
  check_eq (List.length !staged) 1

let confirmed_delete_stages_one_operation_and_removes_only_selected_row () =
  let staged = ref [] in
  let orders =
    match Fractional.n_between (Some "a0") None 100 with
    | Ok values -> values
    | Error message -> failwith message
  in
  let tail =
    List.mapi
      (fun index order ->
        {
          (synced_block (Printf.sprintf "delete-tail-%d" index) "Unrelated") with
          Model.order = Some order;
        })
      orders
  in
  let projected = ref (synced_block "selected" "Selected" :: tail) in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 91);
           graph_blocks = Some (fun () -> Some !projected);
           stage_operation =
             Some
               (fun operation ->
                 staged := !staged @ [ operation ];
                 (match operation.Ops.intent with
                  | Ops.Delete_blocks change ->
                    projected :=
                      List.filter
                        (fun (block : Model.block) ->
                          not (List.mem block.uuid change.uuids))
                        !projected
                  | _ -> ignore !projected);
                 Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  let selected =
    outliner_event session "{\"type\":\"longPressBlock\",\"uuid\":\"selected\"}"
  in
  check_eq
    (json_items "selectedBlockIds" (member "outlinerState" selected))
    [ `String "selected" ];
  check_eq
    (member "type" (List.hd (json_items "outlinerCommands" selected)))
    (`String "haptic");
  ignore (outliner_event session "{\"type\":\"toolbar\",\"action\":\"delete\"}");
  let confirmed = outliner_event session "{\"type\":\"confirmDelete\"}" in
  let splices = json_items "outlinerRowSplices" confirmed in
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  check_eq operation.Ops.base_t 91;
  (match operation.intent with
   | Ops.Delete_blocks change -> check_eq change.uuids [ "selected" ]
   | _ -> check false);
  check_eq (member "isOutlinerPatch" confirmed) (`Bool true);
  check (json_items "blocks" confirmed = []);
  check (json_items "outlinerRows" confirmed = []);
  check_eq (json_items "deletedBlockIds" confirmed) [ `String "selected" ];
  check_eq (List.length splices) 1;
  check_eq (member "start" (List.hd splices)) (`Int 0);
  check_eq (member "deleteCount" (List.hd splices)) (`Int 1);
  check (json_items "rows" (List.hd splices) = []);
  check
    (json_items "selectedBlockIds" (member "outlinerState" confirmed) = [])

let task_status_stages_canonical_property_reference () =
  let staged = ref [] in
  let session =
    staging_session 92 (ref [ synced_block "task" "Task" ]) staged
  in
  ignore
    (outliner_event session
       "{\"type\":\"setTaskStatus\",\"uuid\":\"task\",\"statusIdent\":\"user.status/waiting\"}");
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  check_eq operation.Ops.base_t 92;
  match operation.intent with
  | Ops.Set_property change ->
    check_eq change.uuid "task";
    check_eq change.attr "logseq.property/status";
    check (change.expected = None);
    check_eq change.value (Some (Ops.Ref_ident "user.status/waiting"))
  | _ -> check false

let collapse_and_zoom_replace_only_affected_row_ranges () =
  let parent = synced_block "parent" "Parent" in
  let child =
    { (synced_block "child" "Child") with Model.parent_id = Some "parent" }
  in
  let sibling =
    { (synced_block "sibling" "Sibling") with Model.order = Some "a1" }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks = Some (fun () -> Some [ child; sibling; parent ]);
      }
  in
  let collapsed =
    outliner_event session "{\"type\":\"toggleCollapsed\",\"uuid\":\"parent\"}"
  in
  let splices = json_items "outlinerRowSplices" collapsed in
  check (json_items "outlinerRows" collapsed = []);
  check_eq (List.length splices) 1;
  let splice = List.hd splices in
  let rows = json_items "rows" splice in
  check_eq (member "start" splice) (`Int 0);
  check_eq (member "deleteCount" splice) (`Int 2);
  check_eq (List.length rows) 1;
  check_eq
    (member "uuid" (member "block" (List.hd rows)))
    (`String "parent");
  check_eq (member "isCollapsed" (List.hd rows)) (`Bool true);
  let zoomed =
    outliner_event session "{\"type\":\"zoomIn\",\"uuid\":\"parent\"}"
  in
  let splices = json_items "outlinerRowSplices" zoomed in
  check_eq
    (json_items "zoomedBlockIds" (member "outlinerState" zoomed))
    [ `String "parent" ];
  check_eq (List.length splices) 1;
  check_eq (member "start" (List.hd splices)) (`Int 1);
  check_eq (member "deleteCount" (List.hd splices)) (`Int 1);
  check (json_items "rows" (List.hd splices) = [])

let queued_title_operation operation_id title : Ops.pending_operation =
  {
    operation_id;
    base_t = 42;
    state = Ops.Queued;
    intent =
      Ops.Save_title { uuid = "remote"; expected_title = "Old"; title };
  }

let projected_title_updates_stage_semantic_transactions () =
  let staged = ref [] in
  let session =
    staging_session 42 (ref [ synced_block "remote" "Old" ]) staged
  in
  ignore
    (response_result
       (dispatch_json session "updateBlock"
          "{\"uuid\":\"remote\",\"operationId\":\"op-title\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}"));
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  check_eq operation.Ops.operation_id "op-title";
  check_eq operation.base_t 42;
  (match operation.intent with
   | Ops.Save_title change ->
     check_eq change.uuid "remote";
     check_eq change.expected_title "Old";
     check_eq change.title "Pending"
   | _ -> check false);
  match pending_request (dispatch_json session "beginPendingSync" "") with
  | Some request ->
    let body = member "bodyObject" request in
    let tx = List.hd (json_items "txs" body) in
    check_eq (member "method" request) (`String "WS");
    check_eq (member "t-before" body) (`Int 42);
    check_eq (member "tx-id" tx) (`String "op-title");
    check_eq (member "outliner-op" tx) (`String "save-block")
  | None -> check false

let startup_restores_durable_operations_without_restaging_each_edit () =
  let stage_calls = ref 0 in
  let pending =
    List.init 200 (fun index ->
        queued_title_operation
          (Printf.sprintf "restored-%d" index)
          (Printf.sprintf "Pending %d" index))
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_blocks =
             Some (fun () -> Some [ synced_block "remote" "Old" ]);
           stage_operation =
             Some
               (fun _ ->
                 incr stage_calls;
                 Ok ());
           prepare_operation = Some prepare_operation;
           pending_operations = Some (fun () -> pending);
         })
  in
  check (pending_request (dispatch_json session "beginPendingSync" "") <> None);
  check_eq !stage_calls 0

let stale_queue_head_waits_for_reconciliation_before_advancing () =
  let stale = queued_title_operation "stale-head" "Stale" in
  let valid = queued_title_operation "valid-after-stale" "Valid" in
  let pending = ref [ stale; valid ] in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_blocks =
             Some (fun () -> Some [ synced_block "remote" "Old" ]);
           stage_operation = Some (fun _ -> Ok ());
           prepare_operation =
             Some
               (fun operation ->
                 if operation.Ops.operation_id = "stale-head" then
                   Error "block no longer exists"
                 else prepare_operation operation);
           pending_operations = Some (fun () -> !pending);
         })
  in
  check (pending_request (dispatch_json session "beginPendingSync" "") = None);
  pending := [ valid ];
  match pending_request (dispatch_json session "beginPendingSync" "") with
  | Some request ->
    let tx =
      List.hd (json_items "txs" (member "bodyObject" request))
    in
    check_eq (member "tx-id" tx) (`String "valid-after-stale")
  | None -> check false

let pending_sync_response_is_bounded_independently_of_page_size () =
  let pending = queued_title_operation "bounded-pending" "Pending" in
  let blocks =
    synced_block "remote" "Old"
    :: List.init 500 (fun index ->
           synced_block (Printf.sprintf "tail-%d" index)
             (Printf.sprintf "Tail %d" index))
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_blocks = Some (fun () -> Some blocks);
           stage_operation = Some (fun _ -> Ok ());
           prepare_operation = Some prepare_operation;
           pending_operations = Some (fun () -> [ pending ]);
         })
  in
  let response =
    Session.call session
      "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"beginPendingSync\"}}"
  in
  let result = response_result (Json.from_string response) in
  check_eq (member "isPendingSyncPatch" result) (`Bool true);
  check (json_items "blocks" result = []);
  check (String.length response < 5000)

let semantic_completion_persists_accepted_server_cursor () =
  let staged = ref [] in
  let session =
    staging_session 42 (ref [ synced_block "remote" "Old" ]) staged
  in
  ignore
    (dispatch_json session "updateBlock"
       "{\"uuid\":\"remote\",\"operationId\":\"op-accepted\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}");
  ignore (dispatch_json session "beginPendingSync" "");
  ignore
    (dispatch_json session "completePendingSync"
       "{\"id\":1,\"status\":200,\"body\":\"{\\\"type\\\":\\\"tx/batch/ok\\\",\\\"t\\\":44}\",\"error\":null}");
  let operation = List.nth !staged (List.length !staged - 1) in
  check_eq operation.Ops.operation_id "op-accepted";
  check_eq operation.state (Ops.Accepted 44)

let http_acceptance_waits_for_the_confirmed_journal_cursor () =
  let staged = ref [] in
  let cursor = ref 42 in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some !cursor);
           graph_blocks =
             Some (fun () -> Some [ synced_block "remote" "Old" ]);
           stage_operation =
             Some
               (fun operation ->
                 staged :=
                   operation
                   :: List.filter
                        (fun (op : Ops.pending_operation) ->
                          op.operation_id <> operation.Ops.operation_id)
                        !staged
                   |> List.rev;
                 Ok ());
           prepare_operation = Some prepare_operation;
           pending_operations =
             Some (fun () -> List.filter retryable_operation !staged);
         })
  in
  ignore
    (response_result
       (dispatch_json session "updateBlock"
          "{\"uuid\":\"remote\",\"operationId\":\"first-after-response\",\"expectedTitle\":\"Old\",\"title\":\"First\",\"status\":null}"));
  let completion =
    complete_request session (required_pending_request session)
      "{\"type\":\"tx/batch/ok\",\"t\":43}"
  in
  check_eq (member "appliedServerT" completion) (`Int 42);
  ignore
    (response_result
       (dispatch_json session "updateBlock"
          "{\"uuid\":\"remote\",\"operationId\":\"second-after-response\",\"expectedTitle\":\"First\",\"title\":\"Second\",\"status\":null}"));
  check_eq (pending_request (dispatch_json session "beginPendingSync" "")) None;
  cursor := 43;
  check_eq
    (member "t-before"
       (member "bodyObject" (required_pending_request session)))
    (`Int 43)

let captures_after_acceptance_still_stage_against_authoritative_cursor () =
  let staged = ref [] in
  let source = synced_block "accepted-before-sse" "First" in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_blocks = Some (fun () -> Some [ source ]);
           stage_operation =
             Some
               (fun (operation : Ops.pending_operation) ->
                 if
                   (operation.state = Ops.Queued
                    || operation.state = Ops.Applied)
                   && operation.base_t <> 42
                 then Error "operation was created against a stale server cursor"
                 else (
                   staged :=
                     operation
                     :: List.filter
                          (fun op ->
                            op.Ops.operation_id <> operation.operation_id)
                          !staged
                      |> List.rev;
                   Ok ()));
           prepare_operation = Some prepare_operation;
           pending_operations =
             Some (fun () -> List.filter retryable_operation !staged);
         })
  in
  ignore
    (response_result
       (dispatch_json session "updateBlock"
          "{\"uuid\":\"accepted-before-sse\",\"operationId\":\"accepted-first\",\"expectedTitle\":\"First\",\"title\":\"Updated\",\"status\":null}"));
  ignore
    (complete_request session (required_pending_request session)
       "{\"type\":\"tx/batch/ok\",\"t\":43}");
  List.iter
    (fun (action, payload) ->
      ignore (response_result (dispatch_json session action payload)))
    [
      ( "send",
        "{\"text\":\"After acceptance\",\"uuid\":\"capture-after-acceptance\",\"now\":1788000000000}" );
      ( "sendTask",
        "{\"text\":\"Task after acceptance\",\"uuid\":\"task-after-acceptance\",\"now\":1788000000001,\"status\":{\"uuid\":\"todo\",\"ident\":\"logseq.property/status.todo\",\"title\":\"Todo\"}}" );
      ( "addAsset",
        "{\"uuid\":\"2f659891-3fbc-492c-8943-9e08de2ed949\",\"title\":\"photo.jpg\",\"now\":1788000000002,\"assetType\":\"jpg\",\"assetSize\":4,\"assetChecksum\":\"abcd\",\"localPath\":\"Assets/photo.jpg\",\"targetBlockId\":\"accepted-before-sse\"}" );
    ];
  ignore
    (outliner_block_event session "tapBlock" "accepted-before-sse");
  ignore
    (outliner_block_event session "returnPressed" "accepted-before-sse");
  let operation = List.nth !staged (List.length !staged - 1) in
  check_eq operation.Ops.state Ops.Queued;
  check_eq operation.base_t 42

let rejected_and_offline_transactions_remain_retryable_with_stable_identity () =
  List.iter
    (fun offline ->
      let persisted = ref [] in
      let cursor = ref 42 in
      let operation_id = if offline then "op-retry" else "op-rejected" in
      let session =
        configure_plain_session
          (Session.create_session
             {
               Session.default_options with
               load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
               sync_cursor = Some (fun () -> Some !cursor);
               graph_blocks =
                 Some (fun () -> Some [ synced_block "remote" "Old" ]);
               stage_operation =
                 Some
                   (fun operation ->
                     persisted :=
                       operation
                       :: List.filter
                            (fun (op : Ops.pending_operation) ->
                              op.operation_id <> operation.Ops.operation_id)
                            !persisted
                       |> List.rev;
                     Ok ());
               prepare_operation = Some prepare_operation;
               pending_operations =
                 Some (fun () -> List.filter retryable_operation !persisted);
             })
      in
      ignore
        (response_result
           (dispatch_json session "updateBlock"
              (Printf.sprintf
                 "{\"uuid\":\"remote\",\"operationId\":\"%s\",\"expectedTitle\":\"Old\",\"title\":\"Pending\",\"status\":null}"
                 operation_id)));
      let request = required_pending_request session in
      (if offline then begin
         for _ = 0 to 3 do
         ignore
           (response_result
              (dispatch_json session "completePendingSync"
                 (Json.to_string
                    (Rpc.json_object
                       [
                         ("id", member "id" request);
                         ("status", `Null);
                         ("body", `Null);
                         ("error", `String "offline");
                       ]))))
         done
       end
       else
         ignore
           (complete_request session request
              "{\"type\":\"tx/reject\",\"reason\":\"stale\",\"t\":43}"));
      check_eq (List.length !persisted) 1;
      let operation = List.hd !persisted in
      check_eq operation.Ops.operation_id operation_id;
      check_eq operation.state Ops.Retryable;
      if not offline then begin
        check_eq (pending_request (dispatch_json session "beginPendingSync" "")) None;
        cursor := 43
      end;
      let tx =
        List.hd
          (json_items "txs"
             (member "bodyObject" (required_pending_request session)))
      in
      check_eq (member "tx-id" tx) (`String operation_id))
    [ false; true ]

let delete_block_stages_a_cursor_guarded_semantic_request () =
  let staged = ref [] in
  let session =
    staging_session 77 (ref [ synced_block "delete-me" "Delete me" ]) staged
  in
  ignore
    (response_result
       (dispatch_json session "deleteBlock"
          "{\"uuid\":\"delete-me\",\"operationId\":\"op-delete\",\"expectedServerT\":77}"));
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  check_eq operation.Ops.operation_id "op-delete";
  check_eq operation.base_t 77;
  (match operation.intent with
   | Ops.Delete_blocks deletion -> check_eq deletion.uuids [ "delete-me" ]
   | _ -> check false);
  assert_semantic_request session "op-delete" "delete-blocks" 77

let split_block_stages_one_atomic_semantic_intent () =
  let staged = ref [] in
  let session =
    staging_session 42 (ref [ synced_block "source" "hello world" ]) staged
  in
  ignore
    (response_result
       (dispatch_json session "splitBlock"
          "{\"uuid\":\"source\",\"operationId\":\"op-split\",\"expectedServerT\":42,\"expectedTitle\":\"hello world\",\"before\":\"hello\",\"after\":\" world\",\"newUuid\":\"new\",\"newOrder\":\"a1\",\"createdAt\":100}"));
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  check_eq operation.Ops.operation_id "op-split";
  (match operation.intent with
   | Ops.Split_block split ->
     check_eq split.uuid "source";
     check_eq split.expected_title "hello world";
     check_eq split.before "hello";
     check_eq split.after " world";
     check_eq split.new_uuid "new";
     check_eq split.new_order "a1";
     check_eq split.created_at 100
   | _ -> check false);
  assert_semantic_request session "op-split" "split-block" 42

let confirmed_journal_releases_next_durable_operation () =
  let persisted = ref [] in
  let cursor = ref 42 in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some !cursor);
           graph_blocks =
             Some (fun () -> Some [ synced_block "source" "Old" ]);
           stage_operation =
             Some
               (fun operation ->
                 persisted :=
                   operation
                   :: List.filter
                        (fun (op : Ops.pending_operation) ->
                          op.operation_id <> operation.Ops.operation_id)
                        !persisted
                   |> List.rev;
                 Ok ());
           prepare_operation = Some prepare_operation;
           pending_operations =
             Some (fun () -> List.filter retryable_operation !persisted);
         })
  in
  persisted :=
    List.map
      (fun (operation_id, expected_title, title) ->
        {
          Ops.operation_id;
          base_t = 42;
          state = Ops.Queued;
          intent =
            Ops.Save_title
              { uuid = "source"; expected_title; title };
        })
      [ ("first", "Old", "First"); ("second", "First", "Second") ];
  let completion =
    complete_request session (required_pending_request session) "{\"t\":43}"
  in
  check_eq (member "pendingSyncRequest" completion) `Null;
  cursor := 43;
  let request = required_pending_request session in
  let tx = List.hd (json_items "txs" (member "bodyObject" request)) in
  check_eq (member "tx-id" tx) (`String "second")

let merge_backward_stages_one_atomic_semantic_intent () =
  let staged = ref [] in
  let session =
    staging_session 43
      (ref
         [
           synced_block "previous" "hello"; synced_block "source" " world";
         ])
      staged
  in
  ignore
    (response_result
       (dispatch_json session "mergeBackward"
          "{\"uuid\":\"source\",\"operationId\":\"op-merge\",\"expectedServerT\":43,\"expectedTitle\":\" world\",\"title\":\" world\",\"previousUuid\":\"previous\",\"expectedPreviousTitle\":\"hello\"}"));
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  check_eq operation.Ops.operation_id "op-merge";
  match operation.intent with
  | Ops.Merge_backward merge ->
    check_eq merge.uuid "source";
    check_eq merge.expected_title " world";
    check_eq merge.title " world";
    check_eq merge.previous_uuid "previous";
    check_eq merge.expected_previous_title "hello";
    check (merge.merged_title = None)
  | _ -> check false

let move_blocks_stages_one_ordered_batch () =
  let staged = ref [] in
  let session =
    staging_session 50
      (ref [ synced_block "first" "First"; synced_block "second" "Second" ])
      staged
  in
  ignore
    (response_result
       (dispatch_json session "moveBlocks"
          "{\"operationId\":\"op-move-batch\",\"expectedServerT\":50,\"moves\":[{\"uuid\":\"first\",\"pageUuid\":\"page\",\"parentUuid\":\"target\",\"order\":\"a0\"},{\"uuid\":\"second\",\"pageUuid\":\"page\",\"parentUuid\":\"target\",\"order\":\"a1\"}]}"));
  check_eq (List.length !staged) 1;
  (match (List.hd !staged).Ops.intent with
   | Ops.Move_blocks (batch : Ops.pending_moves) ->
     check_eq
       (List.map (fun (m : Ops.pending_move) -> m.Ops.uuid) batch.moves)
       [ "first"; "second" ]
   | _ -> check false);
  assert_semantic_request session "op-move-batch" "move-blocks" 50

let delete_blocks_stages_one_deduplicated_batch () =
  let staged = ref [] in
  let session =
    staging_session 51
      (ref [ synced_block "first" "First"; synced_block "second" "Second" ])
      staged
  in
  ignore
    (response_result
       (dispatch_json session "deleteBlocks"
          "{\"operationId\":\"op-delete-batch\",\"expectedServerT\":51,\"uuids\":[\"second\",\"first\",\"first\"]}"));
  check_eq (List.length !staged) 1;
  match (List.hd !staged).Ops.intent with
  | Ops.Delete_blocks deletion ->
    check_eq deletion.uuids [ "first"; "second" ]
  | _ -> check false

let status_update_stages_a_typed_property_intent () =
  let staged = ref [] in
  let session =
    staging_session 88 (ref [ synced_block "task" "Task" ]) staged
  in
  ignore
    (response_result
       (dispatch_json session "updateBlockStatus"
          "{\"uuid\":\"task\",\"operationId\":\"op-status\",\"expectedStatusUuid\":null,\"status\":{\"uuid\":\"doing\",\"title\":\"Doing\"}}"));
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  check_eq operation.Ops.operation_id "op-status";
  (match operation.intent with
   | Ops.Set_property property ->
     check_eq property.uuid "task";
     check_eq property.attr "logseq.property/status";
     check (property.expected = None);
     check_eq property.value (Some (Ops.Ref_uuid "doing"))
   | _ -> check false);
  assert_semantic_request session "op-status" "save-block" 88

let delete_without_authoritative_cursor_does_not_stage () =
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> None);
           graph_blocks =
             Some (fun () -> Some [ synced_block "delete-me" "Delete me" ]);
           stage_operation =
             Some (fun _ -> failwith "delete without cursor must not stage");
           prepare_operation = Some prepare_operation;
         })
  in
  let response =
    dispatch_json session "deleteBlock"
      "{\"uuid\":\"delete-me\",\"operationId\":\"op-delete\",\"expectedServerT\":77}"
  in
  check_eq (member "ok" response) (`Bool false);
  check_eq
    (member "code" (member "error" response))
    (`String "stale_server_cursor")

let offline_title_edits_remain_visible_over_authoritative_blocks () =
  let block =
    {
      (Model.local_block "offline-edit" "Server title" "journal/2026-08-15" None
         1776000000000) with
      Model.sync_status = "synced";
    }
  in
  let projected = ref [ block ] in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 5);
           graph_blocks = Some (fun () -> Some !projected);
           stage_operation =
             Some
               (fun operation ->
                 (match operation.Ops.intent with
                  | Ops.Save_title change ->
                    projected :=
                      List.map
                        (fun (block : Model.block) ->
                          if block.uuid = change.uuid then
                            {
                              block with
                              title = change.title;
                              sync_status = "pending";
                            }
                          else block)
                        !projected
                  | _ -> failwith "offline edit must stage Save_title");
                 Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  let result =
    response_result
      (dispatch_json session "updateBlock"
         "{\"uuid\":\"offline-edit\",\"operationId\":\"offline-edit-op\",\"expectedTitle\":\"Server title\",\"title\":\"Edited offline\"}")
  in
  let blocks = json_items "blocks" result in
  check_eq (List.length blocks) 1;
  check_eq (member "title" (List.hd blocks)) (`String "Edited offline");
  check_eq (member "syncStatus" (List.hd blocks)) (`String "pending")

let consecutive_structural_edits_stay_local_and_submit_in_dependency_order () =
  let orders =
    match Fractional.n_between (Some "a0") None 100 with
    | Ok values -> values
    | Error message -> failwith message
  in
  let tail =
    List.mapi
      (fun index order ->
        {
          (synced_block (Printf.sprintf "unrelated-%d" index) "Unrelated") with
          Model.order = Some order;
        })
      orders
  in
  let projected = ref (synced_block "source" "Hello" :: tail) in
  let server_t = ref 42 in
  let authoritative = ref [ "source" ] in
  let prepare_calls = ref 0 in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some !server_t);
           graph_blocks = Some (fun () -> Some !projected);
           stage_operation =
             Some
               (fun operation ->
                 (match operation.Ops.intent with
                  | Ops.Split_block change ->
                    projected :=
                      (let original =
                         required_matching_item
                           (fun (b : Model.block) -> b.uuid = change.uuid)
                           !projected
                       in
                       List.map
                         (fun (b : Model.block) ->
                           if b.uuid = change.uuid then
                             { b with title = change.before }
                           else b)
                         !projected
                       @ [
                           {
                             original with
                             uuid = change.new_uuid;
                             title = change.after;
                             order = Some change.new_order;
                             created_at = change.created_at;
                             updated_at = change.created_at;
                           };
                         ])
                  | Ops.Merge_backward change ->
                    projected :=
                      (let previous =
                         required_matching_item
                           (fun (b : Model.block) ->
                             b.uuid = change.previous_uuid)
                           !projected
                       in
                       List.filter
                         (fun (b : Model.block) -> b.uuid <> change.uuid)
                         (List.map
                            (fun (b : Model.block) ->
                              if b.uuid = change.previous_uuid then
                                {
                                  b with
                                  title = previous.title ^ change.title;
                                }
                              else b)
                            !projected))
                  | _ -> ignore !projected);
                 Ok ());
           prepare_operation =
             Some
               (fun operation ->
                 incr prepare_calls;
                 let ready =
                   match operation.Ops.intent with
                   | Ops.Split_block change ->
                     List.mem change.uuid !authoritative
                   | Ops.Merge_backward change ->
                     List.mem change.uuid !authoritative
                     && List.mem change.previous_uuid !authoritative
                   | _ -> true
                 in
                 if ready then prepare_operation operation
                 else Error "block no longer exists");
         })
  in
  ignore (outliner_block_event session "tapBlock" "source");
  ignore
    (outliner_event session
       "{\"type\":\"textChanged\",\"title\":\"Hello\",\"caretUTF16Offset\":5}");
  let first_split = outliner_block_event session "returnPressed" "source" in
  let first_uuid = editing_uuid first_split in
  let second_split = outliner_block_event session "returnPressed" first_uuid in
  let second_uuid = editing_uuid second_split in
  let merged = outliner_block_event session "backspacePressed" second_uuid in
  let stale_repeat = outliner_block_event session "backspacePressed" second_uuid in
  let merged_again = outliner_block_event session "backspacePressed" first_uuid in
  List.iter assert_bounded_structural_patch
    [ first_split; second_split; merged; merged_again ];
  check_eq (editing_uuid merged) first_uuid;
  check_eq (editing_uuid stale_repeat) first_uuid;
  check_eq (editing_uuid merged_again) "source";
  check_eq !prepare_calls 0;
  let first_request = required_pending_request session in
  authoritative := !authoritative @ [ first_uuid ];
  server_t := 43;
  ignore (complete_request session first_request "{\"t\":43}");
  let second_request = required_pending_request session in
  (let body = member "bodyObject" second_request in
   let tx = List.hd (json_items "txs" body) in
   check_eq (member "t-before" body) (`Int 43);
   check_eq (member "outliner-op" tx) (`String "split-block");
   authoritative := !authoritative @ [ second_uuid ];
   server_t := 44;
   ignore (complete_request session second_request "{\"t\":44}"));
  let body =
    member "bodyObject" (required_pending_request session)
  in
  let tx = List.hd (json_items "txs" body) in
  check_eq (member "t-before" body) (`Int 44);
  check_eq (member "outliner-op" tx) (`String "merge-blocks")

let page_scoped_deletes_preserve_optimistic_blocks_with_a_lagging_reader () =
  let page : Model.entity_summary =
    { uuid = "page-lag"; title = "Lagging page" }
  in
  let source =
    {
      (synced_block "page-source" "Hello") with
      Model.page_id = page.uuid;
      parent_id = Some page.uuid;
    }
  in
  let reference =
    {
      (synced_block "other-page-reference" "Links lagging page") with
      Model.page_id = "other-page";
      parent_id = Some "other-page";
      order = Some "a1";
    }
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_sidebar_pages =
             Some
               (fun () ->
                 Some { Graph.favorites = [ page ]; recent_pages = [] });
           graph_page_blocks =
             Some
               (fun uuid -> if uuid = page.uuid then Some [ source ] else None);
           graph_node_references =
             Some
               (fun uuid ->
                 if uuid = page.uuid then Some [ reference ] else None);
           stage_operation = Some (fun _ -> Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore (response_result (dispatch_json session "selectPage" "page-lag"));
  ignore (outliner_block_event session "tapBlock" source.uuid);
  let first_empty =
    editing_uuid (outliner_block_event session "returnPressed" source.uuid)
  in
  let second_empty =
    editing_uuid (outliner_block_event session "returnPressed" first_empty)
  in
  let state = session.Types.state in
  state := { !state with Types.semantic_queue = [] };
  state := { !state with semantic_active = None };
  let previous =
    editing_uuid (outliner_block_event session "backspacePressed" second_empty)
  in
  check_eq previous first_empty;
  check_eq
    (editing_uuid (outliner_block_event session "backspacePressed" previous))
    source.uuid

let node_route_insertion_preserves_order_with_a_lagging_reader () =
  let page : Model.entity_summary =
    { uuid = "node-lag-page"; title = "Node lag page" }
  in
  let source =
    {
      (synced_block "node-lag-source" "Hello") with
      Model.page_id = page.uuid;
      parent_id = Some page.uuid;
    }
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_page_blocks =
             Some
               (fun uuid -> if uuid = page.uuid then Some [ source ] else None);
           graph_node_destination =
             Some
               (fun uuid ->
                 if uuid = page.uuid then Some (page, false) else None);
           stage_operation = Some (fun _ -> Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore
    (response_result
       (dispatch_json session "openNode" "{\"uuid\":\"node-lag-page\"}"));
  ignore (outliner_block_event session "tapBlock" source.uuid);
  let first_empty =
    editing_uuid
      (first_node_route (outliner_block_event session "returnPressed" source.uuid))
  in
  let second_empty =
    editing_uuid
      (first_node_route (outliner_block_event session "returnPressed" first_empty))
  in
  check (first_empty <> second_empty);
  ignore (outliner_block_event session "tapBlock" source.uuid);
  let inserted =
    editing_uuid
      (first_node_route (outliner_block_event session "returnPressed" source.uuid))
  in
  let expected = ref [ source.uuid; inserted; first_empty; second_empty ] in
  check_eq
    (node_row_ids
       (outliner_event session
          "{\"type\":\"caretMoved\",\"caretUTF16Offset\":0}"))
    !expected;
  for _ = 1 to 20 do
    ignore (outliner_block_event session "tapBlock" source.uuid);
    let inserted =
      editing_uuid
        (first_node_route
           (outliner_block_event session "returnPressed" source.uuid))
    in
    expected :=
      source.uuid :: inserted :: List.tl !expected;
    check_eq
      (node_row_ids
         (outliner_event session
            "{\"type\":\"caretMoved\",\"caretUTF16Offset\":0}"))
      !expected
  done

let structural_patches_preserve_empty_boundaries_prefixes_and_suffixes () =
  let a = synced_block "a" "A" in
  let b = { (synced_block "b" "B") with Model.order = Some "a1" } in
  let c = { (synced_block "c" "C") with Model.order = Some "a2" } in
  let renamed = { b with title = "Changed" } in
  List.iter
    (fun (anchored, before, after, position, deleted, inserted, changed, removed) ->
      let session = Session.create_session Session.default_options in
      let context blocks = Outliner.context blocks [] [] in
      let result =
        response_result
          (Json.from_string
             (Session.structural_outliner_patch anchored session
                (context before)
                (Session.state session).outliner_state
                (context after)))
      in
      let splices = json_items "outlinerRowSplices" result in
      check_eq
        (List.map
           (fun b -> json_string (member "uuid" b))
           (json_items "blocks" result))
        changed;
      check_eq
        (List.map json_string (json_items "deletedBlockIds" result))
        removed;
      if deleted = 0 && inserted = [] then check (splices = [])
      else (
        check_eq (List.length splices) 1;
        let splice = List.hd splices in
        check_eq (member "deleteCount" splice) (`Int deleted);
        check_eq
          (List.map
             (fun row -> json_string (member "uuid" (member "block" row)))
             (json_items "rows" splice))
          inserted;
        List.iter
          (fun (key, expected) -> check_eq (member key splice) expected)
          position))
    [
      (true, [], [], [], 0, [], [], []);
      ( true,
        [],
        [ a ],
        [ ("start", `Int 0) ],
        0,
        [ "a" ],
        [ "a" ],
        [] );
      ( true,
        [ a ],
        [],
        [ ("beforeBlockId", `String "a") ],
        1,
        [],
        [],
        [ "a" ] );
      ( true,
        [ a; c ],
        [ a; b; c ],
        [ ("afterBlockId", `String "a"); ("beforeBlockId", `String "c") ],
        0,
        [ "b" ],
        [ "b" ],
        [] );
      ( true,
        [ a; b; c ],
        [ a; c ],
        [ ("afterBlockId", `String "a"); ("beforeBlockId", `String "b") ],
        1,
        [],
        [],
        [ "b" ] );
      ( false,
        [ a; b; c ],
        [ a; renamed; c ],
        [ ("start", `Int 1) ],
        1,
        [ "b" ],
        [ "b" ],
        [] );
      ( true,
        [ a; b ],
        [ a; b; c ],
        [ ("afterBlockId", `String "b"); ("beforeBlockId", `Null) ],
        0,
        [ "c" ],
        [ "c" ],
        [] );
      (false, [ a ], [ a ], [], 0, [], [], []);
    ]

let todo_status () : Model.status =
  {
    uuid = "status-todo";
    title = "Todo";
    ident = Some "logseq.property/status.todo";
    icon_type = None;
    icon_id = None;
    icon_color = None;
  }

let editing_status_uses_live_properties_instead_of_stale_overlay () =
  let page : Model.entity_summary =
    { uuid = "status-page"; title = "Status page" }
  in
  let source =
    {
      (synced_block "status-source" "Task") with
      Model.page_id = page.uuid;
      parent_id = Some page.uuid;
    }
  in
  let live_blocks = ref [ source ] in
  let staged = ref [] in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_sidebar_pages =
             Some
               (fun () ->
                 Some { Graph.favorites = [ page ]; recent_pages = [] });
           graph_page_blocks =
             Some
               (fun uuid ->
                 if uuid = page.uuid then Some !live_blocks else None);
           stage_operation =
             Some (fun operation -> staged := !staged @ [ operation ]; Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore (response_result (dispatch_json session "selectPage" "status-page"));
  ignore (outliner_block_event session "tapBlock" source.uuid);
  live_blocks := [ { source with status = Some (todo_status ()) } ];
  ignore
    (outliner_event session
       "{\"type\":\"setTaskStatus\",\"uuid\":\"status-source\",\"statusIdent\":\"logseq.property/status.doing\"}");
  check_eq (List.length !staged) 1;
  match (List.hd !staged).Ops.intent with
  | Ops.Set_property change ->
    check_eq
      change.expected
      (Some (Ops.Ref_ident "logseq.property/status.todo"))
  | _ -> check false

let split_block_does_not_inherit_task_or_asset_metadata () =
  let page : Model.entity_summary = { uuid = "task-page"; title = "Task page" } in
  let source =
    {
      (synced_block "task-source" "Todo") with
      Model.page_id = page.uuid;
      parent_id = Some page.uuid;
      status = Some (todo_status ());
      tags = [ ({ uuid = "tag-card"; title = "Card" } : Model.entity_summary) ];
      references =
        [ ({ uuid = "reference"; title = "Reference" } : Model.entity_summary) ];
      breadcrumbs =
        [ ({ uuid = "ancestor"; title = "Ancestor" } : Model.entity_summary) ];
      is_asset = true;
      asset_type = Some "image/jpeg";
      asset_size = Some 42;
      asset_checksum = Some "checksum";
      local_path = Some "/tmp/source.jpg";
    }
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_sidebar_pages =
             Some
               (fun () ->
                 Some { Graph.favorites = [ page ]; recent_pages = [] });
           graph_page_blocks =
             Some
               (fun uuid -> if uuid = page.uuid then Some [ source ] else None);
           stage_operation = Some (fun _ -> Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore (response_result (dispatch_json session "selectPage" "task-page"));
  ignore (outliner_block_event session "tapBlock" source.uuid);
  let response =
    outliner_block_event session "returnPressed" source.uuid
  in
  let inserted =
    List.filter
      (fun block -> member "uuid" block <> `String source.uuid)
      (json_items "blocks" response)
  in
  check_eq (List.length inserted) 1;
  let block = List.hd inserted in
  check_eq (member "status" block) `Null;
  List.iter
    (fun key -> check (json_items key block = []))
    [ "tags"; "references"; "breadcrumbs" ];
  check_eq (member "isAsset" block) (`Bool false)

let journal_split_reads_one_page_and_inserts_the_first_child () =
  let page : Model.entity_summary =
    { uuid = "journal-today"; title = "Today" }
  in
  let source =
    {
      (synced_block "journal-source" "Hello") with
      Model.page_id = page.uuid;
      parent_id = Some page.uuid;
      journal = Some ("Today", 20260818);
    }
  in
  let child =
    { source with uuid = "journal-child"; title = "Child"; parent_id = Some source.uuid }
  in
  let orders =
    match Fractional.n_between (Some "a0") None 20 with
    | Ok values -> values
    | Error message -> failwith message
  in
  let distant =
    List.concat_map
      (fun journal_index ->
        let page_id = Printf.sprintf "journal-%d" journal_index in
        List.mapi
          (fun block_index order ->
            {
              (synced_block
                 (Printf.sprintf "%s-block-%d" page_id block_index)
                 "Unrelated") with
              Model.page_id;
              parent_id = Some page_id;
              order = Some order;
              journal = Some (page_id, 20260700 + journal_index);
            })
          orders)
      (List.init 100 (fun i -> i))
  in
  let today_blocks = ref [ source; child ] in
  let full_graph_reads = ref 0 in
  let page_reads = ref 0 in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 42);
           graph_blocks =
             Some
               (fun () ->
                 incr full_graph_reads;
                 Some (distant @ !today_blocks));
           graph_page_blocks =
             Some
               (fun uuid ->
                 check_eq uuid page.uuid;
                 incr page_reads;
                 Some !today_blocks);
           graph_node_destination =
             Some
               (fun uuid ->
                 if uuid = source.uuid then Some (page, true) else None);
           stage_operation =
             Some
               (fun operation ->
                 (match operation.Ops.intent with
                  | Ops.Split_block change ->
                    today_blocks :=
                      (let original =
                         required_matching_item
                           (fun (b : Model.block) -> b.uuid = change.uuid)
                           !today_blocks
                       in
                       List.map
                         (fun (b : Model.block) ->
                           if b.uuid = change.uuid then
                             { b with title = change.before }
                           else b)
                         !today_blocks
                       @ [
                           {
                             original with
                             uuid = change.new_uuid;
                             title = change.after;
                             order = Some change.new_order;
                             created_at = change.created_at;
                             updated_at = change.created_at;
                           };
                         ])
                  | Ops.Atomic [Ops.Save_title change; Ops.Insert_block inserted] ->
                    today_blocks := List.map (fun (block : Model.block) ->
                      if block.uuid = change.uuid then {block with title = change.title} else block) !today_blocks
                      @ [{source with uuid = inserted.uuid; title = inserted.title;
                        parent_id = Some inserted.parent_uuid; page_id = inserted.page_uuid;
                        order = Some inserted.order; created_at = inserted.created_at; updated_at = inserted.created_at}]
                  | _ -> ignore !today_blocks);
                 Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore (outliner_block_event session "tapBlock" source.uuid);
  full_graph_reads := 0;
  page_reads := 0;
  let split =
    outliner_event session
      "{\"type\":\"returnPressed\",\"uuid\":\"journal-source\",\"title\":\"Hello\",\"caretUTF16Offset\":5}"
  in
  let splices = json_items "outlinerRowSplices" split in
  check_eq !full_graph_reads 0;
  check_eq !page_reads 1;
  check_eq (List.length splices) 1;
  let splice = List.hd splices in
  check_eq (member "afterBlockId" splice) (`String source.uuid);
  check_eq (List.length (json_items "rows" splice)) 1

let graph_switching_keeps_optimistic_models_isolated () =
  let graph_a = Model.create None in
  let graph_b = Model.create None in
  let session =
    Session.create_session
      {
        Session.default_options with
        open_graph = Some (fun _ -> Ok ());
        model_for_graph =
          Some
            (fun graph_id -> if graph_id = "graph-a" then graph_a else graph_b);
      }
  in
  let open_graph graph_id =
    response_result
      (dispatch_json session "openGraph"
         (Json.to_string
            (Rpc.json_object
               [
                 ("graphId", `String graph_id);
                 ( "activePath",
                   `String (Printf.sprintf "/graphs/%s/graph.sqlite" graph_id) );
                 ( "checkpointPath",
                   `String
                     (Printf.sprintf "/graphs/%s/sync.checkpoint" graph_id) );
               ])))
  in
  ignore (open_graph "graph-a");
  ignore
    (response_result
       (dispatch_json session "addAsset"
          "{\"uuid\":\"graph-a-asset\",\"title\":\"photo.jpg\",\"now\":1,\"assetType\":\"jpg\",\"assetSize\":4,\"assetChecksum\":\"abcd\",\"localPath\":\"Assets/photo.jpg\"}"));
  check_eq
    (List.length (Model.pending_blocks (Session.state session).model))
    1;
  ignore (open_graph "graph-b");
  check (Model.pending_blocks (Session.state session).model = []);
  ignore (open_graph "graph-a");
  check_eq
    (List.length (Model.pending_blocks (Session.state session).model))
    1

let collapse_finishes_editor_and_saves_title_exactly_once () =
  let staged = ref [] in
  let parent = synced_block "parent" "Parent" in
  let child =
    { (synced_block "child" "Child") with Model.parent_id = Some "parent" }
  in
  let session = staging_session 92 (ref [ parent; child ]) staged in
  ignore (outliner_block_event session "tapBlock" "parent");
  ignore
    (outliner_event session
       "{\"type\":\"textChanged\",\"title\":\"Changed parent\",\"caretUTF16Offset\":14}");
  let result = outliner_block_event session "toggleCollapsed" "parent" in
  check_eq
    (member "editing" (member "outlinerState" result))
    `Null;
  check (json_items "outlinerRowSplices" result <> []);
  check_eq (List.length !staged) 1

let hide_keyboard_saves_before_publishing_editor_dismissal () =
  List.iter (fun fail_save ->
    let live = ref (synced_block "editing" "Original") in
    let active_session = ref None in
    let saves = ref 0 in
    let session = configure_plain_session
      (Session.create_session { Session.default_options with
        load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
        sync_cursor = Some (fun () -> Some 92);
        graph_blocks = Some (fun () -> Some [!live]);
        prepare_operation = Some prepare_operation;
        stage_operation = Some (fun operation ->
          incr saves;
          let session = Option.get !active_session in
          check_eq ~msg:"storage sees the live draft before any dismissal is published"
            (Outliner.editing_title (Types.state session).outliner_state)
            (Some "Latest saved text");
          if fail_save then Error "Local save failed"
          else match operation.Ops.intent with
            | Ops.Save_title title -> live := { !live with title = title.title }; Ok ()
            | _ -> Error "Expected a title save") }) in
    active_session := Some session;
    ignore (outliner_block_event session "tapBlock" "editing");
    ignore (outliner_event session
      "{\"type\":\"textChanged\",\"title\":\"Latest saved text\",\"caretUTF16Offset\":17}");
    let response = dispatch_json session "outlinerEvent"
      "{\"type\":\"toolbar\",\"action\":\"hideKeyboard\"}" in
    check_eq ~msg:"finishing editing attempts one local save" !saves 1;
    if fail_save then begin
      check_eq (member "ok" response) (`Bool false);
      check_eq ~msg:"a failed save retains the editor and latest draft"
        (Outliner.editing_title (Types.state session).outliner_state)
        (Some "Latest saved text")
    end else begin
      let result = response_result response in
      check_eq ~msg:"the successful response dismisses the editor"
        (member "editing" (member "outlinerState" result)) `Null;
      check_eq ~msg:"the dismissed editor is replaced by its saved text"
        (member "title" (List.hd (json_items "blocks" result)))
        (`String "Latest saved text");
      check_eq !live.title "Latest saved text"
    end)
    [false; true]

let autocomplete_creates_page_without_saving_block_draft () =
  let staged = ref [] in
  let session =
    staging_session 92 (ref [ synced_block "editing" "Original" ]) staged
  in
  ignore (outliner_block_event session "tapBlock" "editing");
  ignore
    (outliner_event session
       "{\"type\":\"textChanged\",\"title\":\"Draft [[Novel]]\",\"caretUTF16Offset\":13}");
  let result =
    outliner_event session "{\"type\":\"chooseAutocomplete\",\"value\":\"Novel\"}"
  in
  let editing = member "editing" (member "outlinerState" result) in
  check_eq (member "title" editing) (`String "Draft [[Novel]]");
  check_eq (List.length !staged) 1;
  match Ops.intent_json (List.hd !staged).Ops.intent with
  | `Assoc fields ->
    check
      (List.exists
         (fun (key, value) -> key = "type" && value = `String "create-page")
         fields)
  | _ -> check false

let rec contains_node_reference value =
  match value with
  | `Assoc fields ->
    member "type" value = `String "nodeReference"
    || List.exists (fun (_, child) -> contains_node_reference child) fields
  | `List values -> List.exists contains_node_reference values
  | _ -> false

let saved_title_immediately_renders_new_reference_metadata () =
  let live = ref (synced_block "source" "Original") in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 92);
           graph_blocks = Some (fun () -> Some [ !live ]);
           stage_operation =
             Some
               (fun operation ->
                 (match operation.Ops.intent with
                  | Ops.Save_title fields ->
                    live :=
                      {
                        !live with
                        title = fields.title;
                        references =
                          [
                            ({
                               uuid = "target";
                               title = "New page";
                             }
                              : Model.entity_summary);
                          ];
                      }
                  | _ -> ignore !live);
                 Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore (outliner_block_event session "tapBlock" "source");
  ignore
    (outliner_event session
       "{\"type\":\"textChanged\",\"title\":\"See [[target]]\",\"caretUTF16Offset\":14}");
  check (contains_node_reference (outliner_event session "{\"type\":\"saveEditing\"}"))

let tag_completion_immediately_publishes_tag_metadata () =
  List.iter
    (fun selected_page ->
      let tag_page : Model.entity_summary =
        { uuid = "tag-uuid"; title = "Project" }
      in
      let live = ref (synced_block "source" "Original") in
      let session =
        configure_plain_session
          (Session.create_session
             {
               Session.default_options with
               load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
               sync_cursor = Some (fun () -> Some 92);
               graph_blocks = Some (fun () -> Some [ !live ]);
               graph_page_blocks = Some (fun _ -> Some [ !live ]);
               graph_tag_pages = Some (fun () -> Some [ tag_page ]);
               stage_operation =
                 Some
                   (fun operation ->
                     (match operation.Ops.intent with
                      | Ops.Add_tag value ->
                        check_eq value.tag_uuid "tag-uuid";
                        live := { !live with tags = [ tag_page ] }
                      | _ -> ignore !live);
                     Ok ());
               prepare_operation = Some prepare_operation;
             })
      in
      (if selected_page then
         let state = session.Types.state in
         state :=
           {
             !state with
             selected_sidebar_page =
               Some
                 ({ uuid = (!live).Model.page_id; title = "Page" }
                   : Model.entity_summary);
           });
      ignore (outliner_block_event session "tapBlock" "source");
      ignore
        (outliner_event session
           "{\"type\":\"textChanged\",\"title\":\"Original #Pro\",\"caretUTF16Offset\":13}");
      let result =
        outliner_event session
          "{\"type\":\"chooseAutocomplete\",\"value\":\"tag-uuid\"}"
      in
      let blocks = json_items "blocks" result in
      check_eq (List.length blocks) 1;
      (if List.length blocks = 1 then
         let tags = json_items "tags" (List.hd blocks) in
         check_eq (List.length tags) 1;
         if List.length tags = 1 then
           check_eq (member "uuid" (List.hd tags)) (`String "tag-uuid"));
      check_eq
        (member "title"
           (member "editing" (member "outlinerState" result)))
        (`String "Original");
      ignore
        (outliner_event session
           "{\"type\":\"toolbar\",\"action\":\"hideKeyboard\"}");
      check_eq
        (List.hd (Session.outliner_context session).Outliner.blocks).Model.tags
        [ tag_page ])
    [ false; true ]

let asset_replay_uuid index =
  Printf.sprintf "00000000-0000-4000-8000-00000000000%d" index

let asset_replay_message ?(typ = "pull/ok") before accepted =
  let rows = List.init (accepted - before) (fun i ->
      let index = before - 41 + i in
      let uuid = asset_replay_uuid index in
      let tx = Transit_native.Transit.Json.to_string
          (Value.Array
             [ Value.Array [ Value.Keyword "db/add"; Value.String uuid; Value.Keyword "block/uuid"; Value.Uuid uuid ];
               Value.Array [ Value.Keyword "db/add"; Value.String uuid; Value.Keyword "block/title"; Value.String "photo.jpg" ] ]) in
      Rpc.json_object [ "t", `Int (before + i + 1); "tx", `String tx ]) in
  Json.to_string (Rpc.json_object
      [ "type", `String typ; "t-before", `Int before; "t", `Int accepted; "txs", `List rows ])

let replay_assets session before accepted =
  response_result (dispatch_json session "applySyncEvent" (asset_replay_message before accepted))

let asset_acknowledgements_preserve_applied_cursor_across_replay_timings () =
  List.iter
    (fun timing ->
      let state = Sync_session.create_state "plain-1" "65.33" 42 in
      let schema_entry =
        {
          Codec.default_schema_attr with
          Ds.value_type = Some Ds.UuidType;
          unique = Some Ds.Identity;
          indexed = true;
        }
      in
      let conn = Ds.create_conn ~schema:[ ("block/uuid", schema_entry) ] () in
      let applied = ref 0 in
      let session =
        configure_plain_session
          (Session.create_session
             {
               Session.default_options with
               load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
               sync_cursor =
                 Some (fun () -> Some (Sync_session.applied_server_t state));
               graph_blocks = Some (fun () -> Some []);
               journal_page_id = Some (fun _ -> Some "journal-page");
               stage_operation = Some (fun _ -> Ok ());
               prepare_operation = Some prepare_operation;
               apply_sync_event =
                 Some
                   (fun payload ->
                     let ( let* ) = Result.bind in
                     let* journal = Journal_sync.decode payload in
                     let local = Sync_session.applied_server_t state in
                     let* _ = Journal_sync.apply (fun value -> Ok value) conn local journal in
                     if journal.t > local then begin
                       incr applied;
                       state.applied_server_t := journal.t
                     end;
                     Ok ());
             })
      in
      List.iter
        (fun index ->
          ignore
            (response_result
               (dispatch_json session "addAsset"
                  (Json.to_string
                     (Rpc.json_object
                        [
                          ("uuid", `String (asset_replay_uuid index));
                          ("title", `String "photo.jpg");
                          ("now", `Int (1788000000000 + index));
                          ("assetType", `String "jpg");
                          ("assetSize", `Int 4);
                          ("assetChecksum", `String "abcd");
                          ("localPath", `String "Assets/photo.jpg");
                        ])))))
        [ 1; 2; 3 ];
      List.iter
        (fun index ->
          let upload = required_pending_request session in
          check_eq (member "method" upload) (`String "PUT");
          let transaction =
            member "pendingSyncRequest"
              (complete_request session upload "{\"ok\":true}")
          in
          let before = Sync_session.applied_server_t state in
          let accepted = 42 + index in
          (if timing = `Replay_first then
             ignore (replay_assets session before accepted));
          let completion =
            complete_request session transaction
              (asset_replay_message ~typ:"tx/batch/ok" (accepted - 1) accepted)
          in
          let visible =
            Json_util.to_int (member "appliedServerT" completion)
          in
          let snapshot =
            response_result (dispatch_json session "startWebSocket" "")
          in
          let cursor =
            Json_util.to_int (member "appliedServerT" snapshot)
          in
          check_eq (Sync_session.applied_server_t state) visible;
          check_eq visible cursor;
          if timing = `Ack_first then
            ignore (replay_assets session cursor accepted))
        [ 1; 2; 3 ];
      (if timing = `Deferred then
         ignore (replay_assets session 42 45));
      check_eq !applied 3;
      check_eq (Sync_session.applied_server_t state) 45;
      check_eq
        (List.length
           (List.of_seq (Ds.Db.datoms (Ds.conn_db conn) Ds.Aevt ~a:"block/uuid" ())))
        3)
    [ `Ack_first; `Replay_first; `Deferred ]

let late_http_acknowledgement_cannot_rewind_transport_cursor () =
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           sync_cursor = Some (fun () -> Some 60);
           prepare_operation = Some prepare_operation;
         })
  in
  let operation =
    { (queued_title_operation "late-ack" "New") with Ops.base_t = 60 }
  in
  (let state = session.Types.state in
   state :=
     {
       !state with
       semantic_queue = [ { Types.operation } ];
     });
  (match (Session.state session).config with
   | Some config -> Session.activate_semantic_request session config (Some 43)
   | None -> failwith "expected configured session");
  match (Session.state session).semantic_active with
  | Some active ->
    (match active.request.Api.body with
     | Some body ->
       check_eq
         (member "t-before" (Json.from_string body))
         (`Int 60)
     | None -> check false)
  | None -> check false

let targeted_assets_appear_immediately_in_selected_page_projection () =
  let page : Model.entity_summary =
    { uuid = "selected-page"; title = "Selected page" }
  in
  let parent =
    {
      (Model.local_block "page-parent" "Parent" "selected-page" None 1) with
      Model.parent_id = Some "selected-page";
      order = Some "a0";
      sync_status = "synced";
    }
  in
  let projected = ref [ parent ] in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 5);
           graph_sidebar_pages =
             Some
               (fun () ->
                 Some { Graph.favorites = [ page ]; recent_pages = [] });
           graph_page_blocks =
             Some
               (fun uuid ->
                 Some (if uuid = "selected-page" then !projected else []));
           stage_operation =
             Some
               (fun operation ->
                 (match operation.Ops.intent with
                  | Ops.Create_asset asset ->
                    projected :=
                      !projected
                      @ [
                          {
                            (Model.local_block asset.uuid asset.title
                               asset.page_uuid (Some asset.parent_uuid)
                               asset.created_at) with
                            Model.order = Some asset.order;
                            is_asset = true;
                            asset_type = Some asset.asset_type;
                            asset_size = Some asset.asset_size;
                            asset_checksum = Some asset.asset_checksum;
                          };
                        ]
                  | _ -> failwith "asset projection must stage Create_asset");
                 Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore (response_result (dispatch_json session "selectPage" "selected-page"));
  let result =
    response_result
      (dispatch_json session "addAsset"
         "{\"uuid\":\"visible-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"page-parent\"}")
  in
  check
    (List.exists
       (fun row ->
         member "uuid" (member "block" row) = `String "visible-asset")
       (json_items "outlinerRows" result))

let task_and_asset_capture_return_optimistic_blocks () =
  List.iter
    (fun (action, payload, uuid) ->
      let result =
        response_result
          (dispatch_json
             (Session.create_session Session.default_options)
             action payload)
      in
      let blocks = json_items "blocks" result in
      check_eq (member "uuid" (List.hd blocks)) (`String uuid))
    [
      ( "sendTask",
        "{\"text\":\"Follow up\",\"uuid\":\"task-local\",\"now\":1776000000000,\"status\":{\"uuid\":\"status-waiting\",\"ident\":\"user.status/waiting\",\"title\":\"Waiting\",\"iconType\":\"tabler-icon\",\"iconId\":\"clock\"}}",
        "task-local" );
      ( "addAsset",
        "{\"uuid\":\"asset-local\",\"title\":\"photo.jpg\",\"now\":1776000000001,\"assetType\":\"jpg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.jpg\"}",
        "asset-local" );
    ]

let targeted_assets_retain_parent_and_page_from_cached_block () =
  let session = Session.create_session Session.default_options in
  let target =
    {
      (Model.local_block "editing-block" "Editing" "target-page" None 1) with
      Model.parent_id = Some "target-page";
      sync_status = "synced";
    }
  in
  Model.upsert_blocks (Session.state session).model [ target ] 1;
  ignore
    (dispatch_json session "addAsset"
       "{\"uuid\":\"targeted-asset\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}");
  match Model.read_block (Session.state session).model "targeted-asset" with
  | Some asset ->
    check_eq asset.Model.page_id "target-page";
    check_eq asset.parent_id (Some "editing-block")
  | None -> check false

let targeted_asset_upload_uses_stable_block_uuid () =
  let target =
    {
      (Model.local_block "editing-block" "Editing" "local-page" None 1) with
      Model.parent_id = Some "local-page";
      sync_status = "synced";
    }
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           graph_blocks = Some (fun () -> Some [ target ]);
         })
  in
  ignore
    (dispatch_json session "addAsset"
       "{\"uuid\":\"targeted-upload\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}");
  match pending_request (dispatch_json session "beginPendingSync" "") with
  | Some request ->
    check_eq
      (member "url" request)
      (`String "http://127.0.0.1:8787/assets/plain-1/targeted-upload.m4a")
  | None -> check false

let shared_images_insert_bounded_row_patches_and_normalize_upload_type () =
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
         })
  in
  let result =
    response_result
      (dispatch_json session "addAsset"
         "{\"uuid\":\"shared-image\",\"title\":\"IMG_0002\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}")
  in
  let splices = json_items "outlinerRowSplices" result in
  let rows = json_items "rows" (List.hd splices) in
  check_eq (member "isOutlinerPatch" result) (`Bool true);
  check_eq (List.length splices) 1;
  check_eq (List.length rows) 1;
  check_eq
    (member "uuid" (member "block" (List.hd rows)))
    (`String "shared-image");
  (match Model.read_block (Session.state session).model "shared-image" with
   | Some asset -> check_eq asset.Model.asset_type (Some "jpeg")
   | None -> check false);
  match pending_request (dispatch_json session "beginPendingSync" "") with
  | Some request ->
    check_eq
      (member "url" request)
      (`String "http://127.0.0.1:8787/assets/plain-1/shared-image.jpeg");
    check_eq (member "contentType" request) (`String "image/jpeg")
  | None -> check false

let pending_assets_wait_for_authentication_and_resume_after_configuration () =
  let session = Session.create_session Session.default_options in
  ignore
    (dispatch_json session "configure"
       "{\"baseUrl\":\"https://api.example\",\"graphId\":\"plain-1\",\"token\":\"\"}");
  ignore
    (dispatch_json session "addAsset"
       "{\"uuid\":\"offline-shared-image\",\"title\":\"IMG_0002.JPG\",\"now\":2,\"assetType\":\"image/jpeg\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"Assets/shared-IMG_0002.JPG\"}");
  check (pending_request (dispatch_json session "beginPendingSync" "") = None);
  ignore (configure_plain_session session);
  check (pending_request (dispatch_json session "beginPendingSync" "") <> None)

let asset_payload_errors_do_not_create_local_blocks () =
  let session = Session.create_session Session.default_options in
  List.iter
    (fun payload ->
      let error = member "error" (dispatch_json session "addAsset" payload) in
      check_eq (member "code" error) (`String "invalid_params");
      check_eq
        (member "message" error)
        (`String "addAsset requires complete file metadata"))
    [
      "{}";
      "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetChecksum\":\"hash\",\"localPath\":\"file\"}";
      "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":null,\"assetChecksum\":\"hash\",\"localPath\":\"file\"}";
      "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":\"12\",\"assetChecksum\":\"hash\",\"localPath\":\"file\"}";
      "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"file\",\"now\":false}";
      "{\"uuid\":\"bad\",\"title\":\"Photo\",\"assetType\":\"png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"file\",\"targetBlockId\":3}";
    ];
  check
    (Model.read_block (Session.state session).model "bad" = None);
  List.iter
    (fun (payload, code, message) ->
      let error = member "error" (dispatch_json session "addAsset" payload) in
      check_eq (member "code" error) (`String code);
      check_eq (member "message" error) (`String message))
    [
      ("[]", "invalid_params", "addAsset payload must be an object");
      ("{", "invalid_json", "addAsset payload must be valid JSON");
    ];
  let error =
    member "error"
      (Json.from_string
         (Session.call session
            "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"addAsset\"}}"))
  in
  check_eq (member "code" error) (`String "invalid_params");
  check_eq
    (member "message" error)
    (`String "addAsset requires a JSON payload")

let asset_staging_errors_preserve_cached_file_and_error_category () =
  List.iter
    (fun (cursor, code, message) ->
      let staged = ref 0 in
      let session =
        configure_plain_session
          (Session.create_session
             {
               Session.default_options with
               sync_cursor = Some (fun () -> cursor);
               journal_page_id = Some (fun _ -> Some "journal");
               stage_operation =
                 Some
                   (fun _ ->
                     incr staged;
                     Error "stage rejected");
             })
      in
      let error =
        member "error"
          (dispatch_json session "addAsset"
             "{\"uuid\":\"staged-asset\",\"title\":\"Photo\",\"now\":1776000000000,\"assetType\":\"png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"/local/photo.png\"}")
      in
      check_eq (member "code" error) (`String code);
      check_eq (member "message" error) (`String message);
      check_eq !staged (if cursor <> None then 1 else 0);
      match Model.read_block (Session.state session).model "staged-asset" with
      | Some asset -> check_eq asset.Model.local_path (Some "/local/photo.png")
      | None -> check false)
    [
      (None, "asset_projection_failed", "A current server cursor is required");
      (Some 7, "stage_operation_failed", "stage rejected");
    ]

let asset_workflow_captures_view_before_caching_and_loads_stage_afterward () =
  let cache = Model.create None in
  let events = ref [] in
  let parent = Model.local_block "parent" "Parent" "page" None 1 in
  let result =
    Rpc.add_asset
      (Some
         "{\"uuid\":\"asset\",\"title\":\"Photo\",\"now\":2,\"assetType\":\"image/png\",\"assetSize\":12,\"assetChecksum\":\"hash\",\"localPath\":\"/photo.png\",\"targetBlockId\":\"parent\"}")
      cache
      (fun () -> 2)
      (fun uuid ->
        events := !events @ [ "target" ];
        check_eq uuid "parent";
        Some parent)
      (fun () ->
        events := !events @ [ "view" ];
        check (Model.read_block cache "asset" = None);
        fun () ->
          events := !events @ [ "complete" ];
          "done")
      (fun (asset : Model.block) ->
        events := !events @ [ "prepare" ];
        check_eq asset.uuid "asset";
        Ok
          {
            Ops.operation_id = "operation";
            base_t = 1;
            state = Ops.Queued;
            intent =
              Ops.Create_asset
                {
                  uuid = asset.uuid;
                  title = asset.title;
                  page_uuid = asset.page_id;
                  parent_uuid = "parent";
                  order = "a0";
                  created_at = asset.created_at;
                  asset_type = "png";
                  asset_size = 12;
                  asset_checksum = "hash";
        transcript = None;
                };
          })
      (fun () ->
        events := !events @ [ "load-stage" ];
        check (Model.read_block cache "asset" <> None);
        Some
          (fun (operation : Ops.pending_operation) ->
            events := !events @ [ "stage" ];
            check_eq operation.operation_id "operation";
            Ok ()))
  in
  check_eq result "done";
  check_eq !events
    [ "view"; "target"; "load-stage"; "prepare"; "stage"; "complete" ];
  match Model.read_block cache "asset" with
  | Some asset ->
    check_eq asset.Model.page_id "page";
    check_eq asset.parent_id (Some "parent");
    check_eq asset.asset_type (Some "png")
  | None -> check false

let local_insertions_share_projection_with_journals_nodes_and_editor () =
  List.iter
    (fun (capture, page_id, parent_id, uuid) ->
      let page : Model.entity_summary =
        { uuid = page_id; title = "Aug 23rd, 2026" }
      in
      let journal =
        if capture then Some ("Aug 23rd, 2026", 20260823) else None
      in
      let parent =
        {
          (Model.local_block parent_id "Parent" page_id (Some page_id) 1) with
          Model.sync_status = "synced";
          order = Some "a0";
          journal;
        }
      in
      let projected = ref [ parent ] in
      let staged = ref [] in
      let session =
        configure_plain_session
          (Session.create_session
             {
               Session.default_options with
               load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
               sync_cursor = Some (fun () -> Some 5);
               journal_page_id = Some (fun _ -> Some page_id);
               graph_blocks = Some (fun () -> Some !projected);
               graph_page_blocks =
                 Some
                   (fun id ->
                     Some
                       (List.filter
                          (fun (b : Model.block) -> b.page_id = id)
                          !projected));
               graph_node_destination =
                 Some
                   (fun id ->
                     if id = page_id then Some (page, false) else None);
               stage_operation =
                 Some
                   (fun operation ->
                     (match operation.Ops.intent with
                      | Ops.Insert_block value ->
                        staged :=
                          !staged
                          @ [ (value.uuid, value.page_uuid, value.parent_uuid) ];
                        projected :=
                          !projected
                          @ [
                              {
                                (Model.local_block value.uuid value.title
                                   value.page_uuid (Some value.parent_uuid)
                                   value.created_at) with
                                Model.order = Some value.order;
                                journal;
                              };
                            ]
                      | _ -> failwith "local insertion must stage Insert_block");
                     Ok ());
               prepare_operation = Some prepare_operation;
             })
      in
      let result =
        response_result
          (if capture then
             dispatch_json session "send"
               "{\"text\":\"hello\",\"uuid\":\"local-hello\",\"now\":1787469000000}"
           else
             dispatch_json session "addChildBlock"
               "{\"uuid\":\"local-child\",\"title\":\"Child\",\"parentId\":\"child-parent\",\"now\":10}")
      in
      check_eq
        !staged
        [ (uuid, page_id, if capture then page_id else parent_id) ];
      check
        (List.exists
           (fun block -> member "uuid" block = `String uuid)
           (json_items "blocks" result));
      if capture then (
        let opened =
          response_result
            (dispatch_json session "openNode" "{\"uuid\":\"journal-page\"}")
        in
        let route = List.hd (json_items "nodeRoutes" opened) in
        check
          (List.exists
             (fun block -> member "uuid" block = `String uuid)
             (json_items "blocks" route));
        let tapped =
          response_result
            (dispatch_json session "outlinerEvent"
               "{\"type\":\"tapBlock\",\"uuid\":\"local-hello\"}")
        in
        let route = List.hd (json_items "nodeRoutes" tapped) in
        let editing = member "editing" (member "outlinerState" route) in
        check_eq (member "uuid" editing) (`String uuid)))
    [
      (true, "journal-page", "world", "local-hello");
      (false, "child-page", "child-parent", "local-child");
    ]

let graph_projection_does_not_leak_legacy_cache_blocks () =
  let projected =
    {
      (Model.local_block "projected-only" "Projected" "page" (Some "page") 1) with
      Model.sync_status = "synced";
      order = Some "a0";
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
        graph_blocks = Some (fun () -> Some [ projected ]);
      }
  in
  Model.cache_local_message (Session.state session).model "legacy-only"
    "Must not leak" 10;
  ignore (configure_plain_session session);
  let result =
    response_result
      (dispatch_json session "configure"
         "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}")
  in
  check
    (not
       (List.exists
          (fun block -> member "uuid" block = `String "legacy-only")
          (json_items "blocks" result)))

let child_insertion_validates_fields_before_loading_cursor () =
  let reads = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        sync_cursor =
          Some
            (fun () ->
              incr reads;
              None);
      }
  in
  reads := 0;
  List.iter
    (fun (payload, message) ->
      let error =
        member "error" (dispatch_json session "addChildBlock" payload)
      in
      check_eq (member "code" error) (`String "invalid_params");
      check_eq (member "message" error) (`String message))
    [
      ("{}", "missing field: uuid");
      ("{\"uuid\":1}", "field must be a string: uuid");
      ("{\"uuid\":\"child\"}", "missing field: title");
      ("{\"uuid\":\"child\",\"title\":\"Child\"}", "missing field: parentId");
      ( "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":false}",
        "field must be a string: parentId" );
      ( "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":\"parent\",\"now\":false}",
        "field must be an integer: now" );
      ("[]", "addChildBlock payload must be an object");
    ];
  check_eq !reads 0;
  check_eq
    (response_error_code (dispatch_json session "addChildBlock" "{"))
    "invalid_json"

let child_insertion_without_graph_writes_through_local_parent () =
  let session = Session.create_session Session.default_options in
  let parent = Model.local_block "parent" "Parent" "local-page" None 1 in
  Model.upsert_blocks (Session.state session).model [ parent ] 1;
  ignore
    (response_result
       (dispatch_json session "addChildBlock"
          "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":\"parent\",\"now\":10}"));
  (match Model.read_block (Session.state session).model "child" with
   | Some child ->
     check_eq child.Model.page_id "local-page";
     check_eq child.parent_id (Some "parent");
     check_eq child.created_at 10
   | None -> check false);
  let error =
    member "error"
      (dispatch_json session "addChildBlock"
         "{\"uuid\":\"orphan\",\"title\":\"Child\",\"parentId\":\"missing\",\"now\":10}")
  in
  check_eq (member "code" error) (`String "invalid_params");
  check_eq
    (member "message" error)
    (`String "unknown parent block: missing")

let child_insertion_preserves_cursor_parent_and_staging_errors () =
  List.iter
    (fun (cursor, has_parent, code, message) ->
      let parent = Model.local_block "parent" "Parent" "page" None 1 in
      let session =
        configure_plain_session
          (Session.create_session
             {
               Session.default_options with
               sync_cursor = Some (fun () -> cursor);
               graph_blocks =
                 Some (fun () -> Some (if has_parent then [ parent ] else []));
               stage_operation = Some (fun _ -> Error "stage rejected");
               prepare_operation = Some (fun _ -> Ok ("insert", "[]"));
             })
      in
      let error =
        member "error"
          (dispatch_json session "addChildBlock"
             "{\"uuid\":\"child\",\"title\":\"Child\",\"parentId\":\"parent\",\"now\":10}")
      in
      check_eq (member "code" error) (`String code);
      check_eq (member "message" error) (`String message))
    [
      (None, true, "invalid_params", "A current server cursor is required");
      (Some 7, false, "invalid_params", "parent block is unavailable");
      (Some 7, true, "stage_operation_failed", "stage rejected");
    ]

let child_operation_orders_only_within_the_parent_page () =
  let parent = Model.local_block "parent" "Parent" "page" None 1 in
  let sibling =
    { parent with uuid = "sibling"; parent_id = Some "parent"; order = Some "a2" }
  in
  let earlier = { sibling with uuid = "earlier"; order = Some "a0" } in
  let other_page =
    { sibling with uuid = "other-page"; page_id = "elsewhere"; order = Some "zZ" }
  in
  let other_parent =
    {
      sibling with
      uuid = "other-parent";
      parent_id = Some "elsewhere";
      order = Some "zZ";
    }
  in
  let unordered = { sibling with uuid = "unordered"; order = None } in
  let context =
    Outliner.context
      [ parent; sibling; earlier; other_page; other_parent; unordered ]
      [] []
  in
  let ids = ref 0 in
  let fresh_id () =
    incr ids;
    "operation"
  in
  (match Rpc.child_operation 7 context "child" "Child" "parent" 10 fresh_id with
   | Ok operation ->
     check_eq operation.Ops.operation_id "operation";
     check_eq operation.base_t 7;
     check_eq operation.state Ops.Queued;
     (match operation.intent with
      | Ops.Insert_block child ->
        check_eq child.uuid "child";
        check_eq child.title "Child";
        check_eq child.page_uuid "page";
        check_eq child.parent_uuid "parent";
        check_eq child.order "a3";
        check_eq child.created_at 10
      | _ -> check false)
   | Error _ -> check false);
  check_eq
    (Rpc.child_operation 7 context "child" "Child" "missing" 10 fresh_id)
    (Error "parent block is unavailable");
  check_eq !ids 1

let plain_assets_project_before_upload_and_queue_stable_datom_transactions () =
  let uuid = "2f659891-3fbc-492c-8943-9e08de2ed949" in
  let staged = ref [] in
  let target =
    {
      (Model.local_block "editing-block" "Editing" "target-page"
         (Some "target-page") 1) with
      Model.order = Some "a0";
      sync_status = "synced";
    }
  in
  let projected = ref [ target ] in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 41);
           graph_blocks = Some (fun () -> Some !projected);
           authoritative_graph_blocks = Some (fun () -> Some [ target ]);
           journal_page_id = Some (fun _ -> Some "journal-page");
           stage_operation =
             Some
               (fun operation ->
                 staged := !staged @ [ operation ];
                 (match operation.Ops.intent with
                  | Ops.Create_asset asset ->
                    projected :=
                      [
                        target;
                        {
                          (Model.local_block asset.uuid asset.title "page"
                             (Some "page") 1) with
                          Model.is_asset = true;
                          order = Some "a0";
                          sync_status = "synced";
                        };
                      ]
                  | _ -> ignore !projected);
                 Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore
    (dispatch_json session "addAsset"
       (Printf.sprintf
          "{\"uuid\":\"%s\",\"title\":\"Audio.m4a\",\"now\":2,\"assetType\":\"m4a\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/Audio.m4a\",\"targetBlockId\":\"editing-block\"}"
          uuid));
  check_eq (List.length !staged) 1;
  let operation = List.hd !staged in
  (match operation.Ops.intent with
   | Ops.Create_asset asset -> check_eq asset.uuid uuid
   | _ -> check false);
  check_eq operation.state Ops.Applied;
  (match pending_request (dispatch_json session "beginPendingSync" "") with
   | Some upload ->
     check_eq (member "method" upload) (`String "PUT");
     check_eq
       (member "url" upload)
       (`String
          (Printf.sprintf "http://127.0.0.1:8787/assets/plain-1/%s.m4a" uuid))
   | None -> check false);
  (match
     pending_request
       (dispatch_json session "completePendingSync"
          "{\"id\":1,\"status\":200,\"body\":\"{\\\"ok\\\":true}\",\"error\":null}")
   with
   | Some request ->
     let transactions = json_items "txs" (member "bodyObject" request) in
     check_eq
       (member "url" request)
       (`String "ws://127.0.0.1:8787/sync/plain-1");
     check_eq (List.length transactions) 1;
     check_eq (member "tx-id" (List.hd transactions)) (`String uuid)
   | None -> check false);
  check_eq (List.length !staged) 2;
  let operation = List.nth !staged 1 in
  (match operation.Ops.intent with
   | Ops.Create_asset asset ->
     check_eq asset.uuid uuid;
     check_eq asset.page_uuid "target-page";
     check_eq asset.parent_uuid "editing-block";
     check (asset.order <> "")
   | _ -> check false);
  check_eq operation.state Ops.Queued

let failed_raw_uploads_retry_without_queuing_datoms () =
  let staged = ref [] in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           sync_cursor = Some (fun () -> Some 41);
           journal_page_id = Some (fun _ -> Some "journal-page");
           stage_operation =
             Some (fun operation -> staged := !staged @ [ operation ]; Ok ());
           prepare_operation = Some prepare_operation;
         })
  in
  ignore
    (dispatch_json session "addAsset"
       "{\"uuid\":\"retry-asset\",\"title\":\"photo.png\",\"now\":2,\"assetType\":\"png\",\"assetSize\":2048,\"assetChecksum\":\"abc\",\"localPath\":\"/documents/photo.png\"}");
  match pending_request (dispatch_json session "beginPendingSync" "") with
  | Some first_request ->
    ignore
      (dispatch_json session "completePendingSync"
         "{\"id\":1,\"status\":null,\"body\":null,\"error\":\"offline\"}");
    check_eq (List.length !staged) 1;
    let operation = List.hd !staged in
    (match operation.Ops.intent with
     | Ops.Create_asset asset -> check_eq asset.uuid "retry-asset"
     | _ -> check false);
    check_eq operation.state Ops.Applied;
    (match pending_request (dispatch_json session "beginPendingSync" "") with
     | Some retry ->
       check_eq (member "url" retry) (member "url" first_request)
     | None -> check false)
  | None -> check false

let encrypted_capture_stages_persistent_insert_and_uses_datom_endpoint () =
  let staged = ref [] in
  let existing =
    {
      (Model.local_block "existing-journal-block" "Existing" "journal-page"
         (Some "journal-page") 1) with
      Model.order = Some "a0";
      sync_status = "synced";
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some encrypted_graph_catalog);
        graph_unlocked = Some (fun _ -> true);
        sync_cursor = Some (fun () -> Some 91);
        graph_blocks = Some (fun () -> Some [ existing ]);
        journal_page_id = Some (fun _ -> Some "journal-page");
        stage_operation =
          Some (fun operation -> staged := !staged @ [ operation ]; Ok ());
        prepare_operation = Some prepare_operation;
      }
  in
  ignore (configure_encrypted_session session);
  ignore (dispatch_json session "selectGraph" "encrypted-1");
  ignore
    (dispatch_json session "send"
       "{\"text\":\"Encrypted capture\",\"uuid\":\"encrypted-capture\",\"now\":1776000000000}");
  check_eq (List.length !staged) 1;
  (match (List.hd !staged).Ops.intent with
   | Ops.Insert_block block ->
     check_eq block.uuid "encrypted-capture";
     check_eq block.title "Encrypted capture";
     check_eq block.page_uuid "journal-page";
     check_eq block.parent_uuid "journal-page";
     check (compare block.order "a0" > 0)
   | _ -> check false);
  match pending_request (dispatch_json session "beginPendingSync" "") with
  | Some request ->
    check_eq
      (member "url" request)
      (`String "ws://127.0.0.1:8787/sync/encrypted-1")
  | None -> check false

let page_favorite_updates_sidebar_and_preserves_operation_fields () =
  let favorite = ref false in
  let calls = ref [] in
  let page : Model.entity_summary =
    { uuid = "page-favorite"; title = "Favorite me" }
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           graph_sidebar_pages =
             Some
               (fun () ->
                 Some
                   {
                     Graph.favorites = (if !favorite then [ page ] else []);
                     recent_pages = [ page ];
                   });
           graph_set_page_favorite =
             Some
               (fun page_uuid value operation_id now ->
                 calls := !calls @ [ (page_uuid, value, operation_id, now) ];
                 favorite := value;
                 Ok ());
         })
  in
  let response =
    dispatch_json session "setPageFavorite"
      "{\"pageUuid\":\"page-favorite\",\"favorite\":true,\"operationId\":\"favorite-op\",\"now\":100}"
  in
  check (Json_util.to_bool (member "ok" response));
  check_eq
    (List.length
       (Json_util.to_list (member "favorites" (member "result" response))))
    1;
  ignore
    (dispatch_json session "setPageFavorite"
       "{\"pageUuid\":\"page-favorite\",\"favorite\":false,\"operationId\":\"unfavorite-op\",\"now\":100}");
  check_eq !calls
    [
      ("page-favorite", true, "favorite-op", 100);
      ("page-favorite", false, "unfavorite-op", 100);
    ]

let page_deletion_updates_sidebar_and_preserves_operation_fields () =
  let deleted = ref [] in
  let page : Model.entity_summary =
    { uuid = "page-delete"; title = "Delete me" }
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           graph_sidebar_pages =
             Some
               (fun () ->
                 Some
                   {
                     Graph.favorites = [];
                     recent_pages = (if !deleted = [] then [ page ] else []);
                   });
           graph_delete_page =
             Some
               (fun page_uuid operation_id now ->
                 deleted := !deleted @ [ (page_uuid, operation_id, now) ];
                 Ok ());
         })
  in
  let response =
    dispatch_json session "deletePage"
      "{\"pageUuid\":\"page-delete\",\"operationId\":\"delete-page-op\",\"now\":100}"
  in
  check (Json_util.to_bool (member "ok" response));
  check
    (Json_util.to_list (member "recentPages" (member "result" response)) = []);
  check_eq !deleted [ ("page-delete", "delete-page-op", 100) ]

let flashcard_review_removes_due_card_and_preserves_operation_fields () =
  let now = 1776000000000 in
  let reviewed = ref [] in
  let due_card : Flashcards.due_card =
    {
      block =
        Model.local_block "flashcard" "Question {{cloze answer}}" "page" None now;
      children = [];
      card = Flashcards.new_card now;
    }
  in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
           graph_due_flashcards =
             Some (fun _ -> if !reviewed = [] then [ due_card ] else []);
           graph_review_flashcard =
             Some
               (fun uuid rating at operation_id ->
                 reviewed := !reviewed @ [ (uuid, rating, at, operation_id) ];
                 Ok ());
         })
  in
  ignore (dispatch_json session "loadFlashcards" "1776000000000");
  let response =
    dispatch_json session "reviewFlashcard"
      "{\"uuid\":\"flashcard\",\"rating\":\"good\",\"now\":1776000000000,\"operationId\":\"review-op\"}"
  in
  check (Json_util.to_bool (member "ok" response));
  check
    (Json_util.to_list (member "flashcards" (member "result" response)) = []);
  check_eq !reviewed [ ("flashcard", Flashcards.Good, now, "review-op") ]

let page_and_review_actions_validate_before_calling_services () =
  let calls = ref 0 in
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           graph_set_page_favorite =
             Some
               (fun _ _ _ _ ->
                 incr calls;
                 Ok ());
           graph_delete_page =
             Some
               (fun _ _ _ ->
                 incr calls;
                 Ok ());
           graph_review_flashcard =
             Some
               (fun _ _ _ _ ->
                 incr calls;
                 Ok ());
         })
  in
  List.iter
    (fun (action, wire, message) ->
      let response = dispatch_json session action wire in
      check_eq (response_error_code response) "invalid_params";
      check_eq
        (json_string (member "message" (member "error" response)))
        message)
    [
      ("setPageFavorite", "{}", "missing field: pageUuid");
      ( "setPageFavorite",
        "{\"pageUuid\":1,\"favorite\":1}",
        "field must be a string: pageUuid" );
      ("setPageFavorite", "{\"pageUuid\":\"p\"}", "missing field: favorite");
      ( "setPageFavorite",
        "{\"pageUuid\":\"p\",\"favorite\":null}",
        "field must be a boolean: favorite" );
      ( "setPageFavorite",
        "{\"pageUuid\":\"p\",\"favorite\":true}",
        "missing field: operationId" );
      ( "setPageFavorite",
        "{\"pageUuid\":\"p\",\"favorite\":true,\"operationId\":\"op\",\"now\":false}",
        "field must be an integer: now" );
      ("deletePage", "{}", "missing field: pageUuid");
      ("deletePage", "{\"pageUuid\":\"p\"}", "missing field: operationId");
      ( "deletePage",
        "{\"pageUuid\":\"p\",\"operationId\":\"op\",\"now\":false}",
        "field must be an integer: now" );
      ("reviewFlashcard", "{}", "missing field: uuid");
      ("reviewFlashcard", "{\"uuid\":\"c\"}", "missing field: rating");
      ( "reviewFlashcard",
        "{\"uuid\":\"c\",\"rating\":\"bad\",\"now\":false}",
        "field must be an integer: now" );
      ( "reviewFlashcard",
        "{\"uuid\":\"c\",\"rating\":\"bad\"}",
        "missing field: operationId" );
      ( "reviewFlashcard",
        "{\"uuid\":\"c\",\"rating\":\"bad\",\"operationId\":\"op\"}",
        "rating must be again, hard, good, or easy" );
    ];
  List.iter
    (fun action ->
      check_eq
        (response_error_code (dispatch_json session action "{"))
        "invalid_json";
      check_eq
        (response_error_code (dispatch_json session action "[]"))
        "invalid_params")
    [ "setPageFavorite"; "deletePage"; "reviewFlashcard" ];
  check_eq !calls 0

let page_and_review_actions_preserve_service_errors () =
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           graph_set_page_favorite =
             Some (fun _ _ _ _ -> Error "favorite rejected");
           graph_delete_page = Some (fun _ _ _ -> Error "delete rejected");
           graph_review_flashcard =
             Some (fun _ _ _ _ -> Error "review rejected");
         })
  in
  List.iter
    (fun (action, wire, code, message) ->
      let response = dispatch_json session action wire in
      check_eq (response_error_code response) code;
      check_eq
        (json_string (member "message" (member "error" response)))
        message)
    [
      ( "setPageFavorite",
        "{\"pageUuid\":\"p\",\"favorite\":true,\"operationId\":\"op\"}",
        "set_page_favorite_failed",
        "favorite rejected" );
      ( "deletePage",
        "{\"pageUuid\":\"p\",\"operationId\":\"op\"}",
        "delete_page_failed",
        "delete rejected" );
      ( "reviewFlashcard",
        "{\"uuid\":\"c\",\"rating\":\"good\",\"operationId\":\"op\"}",
        "flashcard_review_failed",
        "review rejected" );
    ];
  let session = Session.create_session Session.default_options in
  List.iter
    (fun (action, code) ->
      check_eq (response_error_code (dispatch_json session action "{}")) code)
    [
      ("setPageFavorite", "set_page_favorite_unavailable");
      ("deletePage", "delete_page_unavailable");
      ("reviewFlashcard", "flashcards_unavailable");
    ]

let page_and_review_actions_preserve_precondition_priority () =
  let calls = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_set_page_favorite =
          Some
            (fun _ _ _ _ ->
              incr calls;
              Ok ());
        graph_delete_page =
          Some
            (fun _ _ _ ->
              incr calls;
              Ok ());
      }
  in
  List.iter
    (fun action ->
      check_eq
        (response_error_code (dispatch_json session action "{"))
        "graph_not_configured")
    [ "setPageFavorite"; "deletePage" ];
  List.iter
    (fun action ->
      let response =
        Json.from_string
          (Session.call session
             (Json.to_string
                (Rpc.json_object
                   [
                     ("apiVersion", `Int 1);
                     ("method", `String "dispatch");
                     ( "params",
                       Rpc.json_object [ ("action", `String action) ] );
                   ])))
      in
      check_eq (response_error_code response) "invalid_params";
      check_eq
        (json_string (member "message" (member "error" response)))
        (action ^ " requires a payload"))
    [ "setPageFavorite"; "deletePage"; "reviewFlashcard" ];
  check_eq !calls 0

let page_service_exceptions_are_not_reclassified_as_payload_json_errors () =
  let session =
    configure_plain_session
      (Session.create_session
         {
           Session.default_options with
           graph_delete_page =
             Some (fun _ _ _ -> failwith "service crashed");
         })
  in
  let response =
    dispatch_json session "deletePage" "{\"pageUuid\":\"p\",\"operationId\":\"op\"}"
  in
  check_eq (response_error_code response) "invalid_json";
  check_eq
    (json_string (member "message" (member "error" response)))
    "request must be valid JSON"

let refresh_reads_local_graph_without_http () =
  List.iter
    (fun response ->
      let requests = ref 0 in
      let status : Model.status =
        { uuid = "todo"; title = "Todo"; ident = None;
          icon_type = Some "tabler-icon"; icon_id = Some "circle";
          icon_color = Some "#7c3aed" }
      in
      let local =
        { (Model.local_block "local" "Offline draft" "journal" None 10) with
          tags = [ { Model.uuid = "tag"; title = "Project" } ];
          references = [ { Model.uuid = "page"; title = "Reference" } ];
          status = Some status }
      in
      let session =
        Session.create_session
          { Session.default_options with
            load_graph_catalog = Some (fun () -> Some plain_graph_catalog);
            graph_blocks = Some (fun () -> Some [ local ]);
            send = (fun _ -> incr requests; response) }
      in
      ignore
        (dispatch_json session "configure"
           "{\"baseUrl\":\"http://127.0.0.1:8787\",\"graphId\":\"plain-1\",\"token\":\"access\"}");
      let model = (Session.state session).model in
      Model.upsert_journal_page model "journal" 20260916 "Today";
      Model.upsert_blocks model [ local ] 10;
      Model.upsert_statuses model [ status ];
      let result = response_result (dispatch_json session "refresh" "") in
      check_eq !requests 0;
      let block = List.hd (json_items "blocks" result) in
      check_eq (member "uuid" block) (`String "local");
      check_eq (member "title" block) (`String "Offline draft");
      check_eq (member "syncStatus" block) (`String "pending");
      check_eq (member "title" (List.hd (json_items "tags" block))) (`String "Project");
      check_eq (member "title" (List.hd (json_items "references" block))) (`String "Reference");
      check_eq (member "color" (member "icon" (member "status" block))) (`String "#7c3aed");
      check_eq (member "uuid" (List.hd (json_items "taskStatuses" result))) (`String "todo");
      check_eq (Model.journal_metadata model "journal") (Some ("Today", 20260916));
      check_eq (Model.read_block model "local") (Some local))
    [ Error "offline"; Ok (Api.response 200 "{\"blocks\":[],\"choices\":[]}") ]

let optimistic_capture_is_returned_before_sync () =
  let session = Session.create_session Session.default_options in
  let response =
    dispatch_json session "send"
      "{\"text\":\"Optimistic capture\",\"uuid\":\"local-swift\",\"now\":1776000000000}"
  in
  let blocks = Json_util.to_list (member "blocks" (member "result" response)) in
  let block = List.hd blocks in
  check_eq (json_string (member "uuid" block)) "local-swift";
  check_eq (json_string (member "title" block)) "Optimistic capture";
  check_eq (json_string (member "syncStatus" block)) "pending";
  check_eq (Json_util.to_int (member "createdAt" block)) 1776000000000

let title_operation wire : Ops.pending_operation =
  {
    operation_id = "original";
    base_t = 42;
    state = Ops.Retryable;
    intent = Ops.intent_of_json (Json.from_string wire);
  }

let title_intent_wires =
  [
    "{\"type\":\"save-title\",\"uuid\":\"b\",\"expectedTitle\":\"old\",\"title\":\"one\"}";
    "{\"type\":\"insert-block\",\"uuid\":\"b\",\"title\":\"one\",\"pageUuid\":\"p\",\"parentUuid\":\"p\",\"order\":\"a0\",\"createdAt\":1}";
    "{\"type\":\"split-block\",\"uuid\":\"b\",\"expectedTitle\":\"old\",\"before\":\"one\",\"after\":\"two\",\"newUuid\":\"new\",\"newOrder\":\"a1\",\"createdAt\":1}";
    "{\"type\":\"merge-backward\",\"uuid\":\"b\",\"expectedTitle\":\"old\",\"title\":\"one\",\"previousUuid\":\"prev\",\"expectedPreviousTitle\":\"previous\",\"mergedTitle\":\"combined\"}";
  ]

let title_normalization_preserves_operation_and_stages_tags_first () =
  let calls = ref 0 in
  let normalize uuid titles =
    check_eq uuid "b";
    incr calls;
    ( List.map (fun t -> "normalized:" ^ t) titles,
      [ ("tag-1", "First"); ("tag-2", "Second") ] )
  in
  List.iter
    (fun wire ->
      let operation = title_operation wire in
      let result =
        Rpc.normalize_operation_titles (Some normalize)
          (fun () -> "new-id")
          (fun () -> 100) operation
      in
      let changed = List.nth result 2 in
      let expected =
        title_operation
          (let s = Str.global_replace (Str.regexp "\"one\"") "\"normalized:one\"" wire in
           Str.global_replace (Str.regexp "\"two\"") "\"normalized:two\"" s)
      in
      check_eq (List.length result) 3;
      check_eq changed.Ops.operation_id "original";
      check_eq changed.base_t 42;
      check_eq changed.state Ops.Retryable;
      List.iter
        (fun index ->
          let tag_op = List.nth result index in
          check_eq tag_op.Ops.base_t 42;
          check_eq tag_op.state Ops.Queued;
          match tag_op.intent with
          | Ops.Create_tag tag ->
            check_eq tag.uuid (List.nth [ "tag-1"; "tag-2" ] index);
            check_eq tag.title (List.nth [ "First"; "Second" ] index);
            check_eq tag.created_at 100
          | _ -> check false)
        [ 0; 1 ];
      check_eq changed expected)
    title_intent_wires;
  check_eq !calls 4

let title_normalization_keeps_original_intent_on_wrong_arity () =
  let normalize _uuid _titles = ([], [ ("tag", "Tag") ]) in
  List.iter
    (fun wire ->
      let operation = title_operation wire in
      let result =
        Rpc.normalize_operation_titles (Some normalize)
          (fun () -> "new-id")
          (fun () -> 100) operation
      in
      check_eq (List.length result) 2;
      check_eq (List.nth result 1) operation)
    title_intent_wires

let title_normalization_skips_unrelated_intents_and_absent_service () =
  let calls = ref 0 in
  let normalize _uuid titles =
    incr calls;
    (titles, [])
  in
  let operation =
    title_operation "{\"type\":\"delete-blocks\",\"uuids\":[\"b\"]}"
  in
  check_eq
    (Rpc.normalize_operation_titles (Some normalize)
       (fun () -> "new-id")
       (fun () -> 100) operation)
    [ operation ];
  check_eq !calls 0;
  List.iter
    (fun wire ->
      let operation = title_operation wire in
      check_eq
        (Rpc.normalize_operation_titles None
           (fun () -> "new-id")
           (fun () -> 100) operation)
        [ operation ])
    title_intent_wires

let capture_requires_projection_cursor_before_looking_up_journal () =
  let calls = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        journal_page_id =
          Some
            (fun _day ->
              incr calls;
              None);
      }
  in
  check_eq
    (Session.capture_operations session "b" "Text" 1776000000000 None)
    (Error "A current server cursor is required");
  check_eq !calls 0

let asset_block uuid =
  {
    (Model.local_block uuid "photo.jpg" "local-page" None 1776000000000) with
    Model.is_asset = true;
    asset_type = Some "jpg";
    asset_size = Some 2048;
    asset_checksum = Some "checksum";
    local_path = Some "Assets/photo.jpg";
  }

let asset_operation_rejects_missing_cursor_before_loading_destination () =
  let loads = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        graph_blocks =
          Some
            (fun () ->
              incr loads;
              Some []);
        journal_page_id =
          Some
            (fun _day ->
              incr loads;
              Some "journal");
      }
  in
  check_eq
    (Session.asset_datoms_operation session (asset_block "a") Ops.Queued)
    (Error "A current server cursor is required");
  check_eq !loads 0

let asset_operation_rejects_incomplete_metadata_before_loading_destination () =
  let loads = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        sync_cursor = Some (fun () -> Some 7);
        graph_blocks =
          Some
            (fun () ->
              incr loads;
              Some []);
        journal_page_id =
          Some
            (fun _day ->
              incr loads;
              Some "journal");
      }
  in
  let asset = asset_block "a" in
  List.iter
    (fun block ->
      check_eq
        (Session.asset_datoms_operation session block Ops.Queued)
        (Error "asset metadata is incomplete"))
    [
      { asset with asset_type = None };
      { asset with asset_size = None };
      { asset with asset_checksum = None };
    ];
  check_eq !loads 0

let asset_operation_does_not_fallback_from_missing_parent_to_journal () =
  let journal_lookups = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        sync_cursor = Some (fun () -> Some 7);
        journal_page_id =
          Some
            (fun _day ->
              incr journal_lookups;
              Some "journal");
      }
  in
  check_eq
    (Session.asset_datoms_operation session
       { (asset_block "a") with parent_id = Some "missing" }
       Ops.Queued)
    (Error "asset destination is not available");
  check_eq !journal_lookups 0

let asset_operation_uses_journal_date_and_preserves_durable_metadata () =
  let days = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        sync_cursor = Some (fun () -> Some 7);
        journal_page_id =
          Some
            (fun day ->
              days := !days @ [ day ];
              Some "journal");
      }
  in
  let asset = asset_block "a" in
  (match Session.asset_datoms_operation session asset Ops.Applied with
   | Ok operation ->
     check_eq operation.Ops.operation_id "asset:a";
     check_eq operation.base_t 7;
     check_eq operation.state Ops.Applied;
     (match operation.intent with
      | Ops.Create_asset value ->
        check_eq value.uuid "a";
        check_eq value.title "photo.jpg";
        check_eq value.page_uuid "journal";
        check_eq value.parent_uuid "journal";
        check_eq value.order "a0";
        check_eq value.created_at 1776000000000;
        check_eq value.asset_type "jpg";
        check_eq value.asset_size 2048;
        check_eq value.asset_checksum "checksum"
      | _ -> check false)
   | Error _ -> check false);
  check_eq !days [ Model.journal_day_for_ms asset.created_at ]

let asset_operation_orders_after_siblings_without_counting_itself () =
  let parent = Model.local_block "parent" "Parent" "page" None 1 in
  let sibling =
    { parent with uuid = "sibling"; parent_id = Some "parent"; order = Some "a2" }
  in
  let earlier = { sibling with uuid = "earlier"; order = Some "a0" } in
  let other_page =
    { sibling with uuid = "other-page"; page_id = "elsewhere"; order = Some "zZ" }
  in
  let other_parent =
    {
      sibling with
      uuid = "other-parent";
      parent_id = Some "elsewhere";
      order = Some "zZ";
    }
  in
  let unordered = { sibling with uuid = "unordered"; order = None } in
  let asset =
    {
      (asset_block "a") with
      parent_id = Some "parent";
      page_id = "page";
      order = Some "zZ";
    }
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        sync_cursor = Some (fun () -> Some 7);
        graph_blocks =
          Some
            (fun () ->
              Some
                [ parent; sibling; earlier; other_page; other_parent; unordered; asset ]);
      }
  in
  match Session.asset_datoms_operation session asset Ops.Queued with
  | Ok operation ->
    check_eq operation.Ops.state Ops.Queued;
    (match operation.intent with
     | Ops.Create_asset value ->
       check_eq value.page_uuid "page";
       check_eq value.parent_uuid "parent";
       check_eq value.order "a3"
     | _ -> check false)
  | Error _ -> check false

let encrypted_asset_upload_stages_datoms_and_cleans_temporary_payload () =
  let cleaned = ref [] in
  let staged = ref [] in
  let checksum =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some encrypted_graph_catalog);
        graph_unlocked = Some (fun _graph_id -> true);
        encrypt_title =
          Some (fun _graph_id title -> Ok ("cipher(" ^ title ^ ")"));
        resolve_asset_path =
          (fun path ->
            check_eq path "Assets/photo.jpg";
            "/documents/Assets/photo.jpg");
        encrypt_asset_file =
          Some
            (fun _graph_id path ->
              check_eq path "/documents/Assets/photo.jpg";
              Ok ("/tmp/photo.transit", 4096));
        journal_page_id = Some (fun _day -> Some "real-journal-page");
        sync_cursor = Some (fun () -> Some 91);
        stage_operation =
          Some
            (fun operation ->
              (match operation.Ops.intent with
               | Ops.Create_asset value ->
                 check_eq value.uuid "asset-async";
                 check_eq value.title "photo.jpg";
                 check_eq value.page_uuid "real-journal-page";
                 check_eq value.parent_uuid "real-journal-page";
                 check_eq value.asset_type "jpg";
                 check_eq value.asset_size 2048;
                 check_eq value.asset_checksum checksum
               | _ -> check false);
              staged := !staged @ [ Ops.state_string operation.state ];
              Ok ());
        prepare_operation = Some prepare_operation;
        cleanup_file =
          (fun path ->
            cleaned := !cleaned @ [ path ]);
      }
  in
  ignore (configure_encrypted_session session);
  ignore (dispatch_json session "selectGraph" "encrypted-1");
  ignore
    (dispatch_json session "addAsset"
       (Printf.sprintf
          "{\"uuid\":\"asset-async\",\"title\":\"photo.jpg\",\"now\":1776000000000,\"assetType\":\"jpg\",\"assetSize\":2048,\"assetChecksum\":\"%s\",\"localPath\":\"Assets/photo.jpg\"}"
          checksum));
  (match pending_request (dispatch_json session "beginPendingSync" "") with
   | Some request ->
     check_eq (json_string (member "method" request)) "PUT";
     check_eq
       (json_string (member "filePath" request))
       "/tmp/photo.transit";
     check_eq (json_string (member "contentType" request)) "text/plain";
     check_eq
       (json_string (member "url" request))
       "http://127.0.0.1:8787/assets/encrypted-1/asset-async.jpg";
     let headers = member "headers" request in
     check_eq
       (json_string (member "x-amz-meta-checksum" headers))
       checksum;
     check_eq (json_string (member "x-amz-meta-type" headers)) "jpg"
   | None -> check false);
  (match
     pending_request
       (dispatch_json session "completePendingSync"
          "{\"id\":1,\"status\":200,\"body\":\"{\\\"ok\\\":true}\",\"error\":null}")
   with
   | Some request ->
     check_eq
       (json_string (member "url" request))
       "ws://127.0.0.1:8787/sync/encrypted-1"
   | None -> check false);
  check_eq !staged [ "applied"; "queued" ];
  check_eq !cleaned [ "/tmp/photo.transit" ]

let graph_creation_validates_before_performing_io () =
  let calls = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        send =
          (fun _request ->
            incr calls;
            Error "unexpected transport");
      }
  in
  check_eq
    (response_error_code (dispatch_json session "createSyncGraph" "{}"))
    "graph_not_configured";
  ignore (configure_encrypted_session session);
  List.iter
    (fun (payload, code) ->
      check_eq
        (response_error_code (dispatch_json session "createSyncGraph" payload))
        code)
    [
      ("{", "invalid_json");
      ("[]", "invalid_params");
      ("{}", "invalid_params");
      ("{\"name\":\"  \",\"isEncrypted\":false}", "invalid_params");
      ("{\"name\":\"Graph\",\"isEncrypted\":\"false\"}", "invalid_params");
    ];
  check_eq !calls 0;
  check_eq
    (response_error_code
       (Json.from_string
          (Session.call session
             "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"createSyncGraph\"}}")))
    "invalid_params"

let graph_creation_preserves_transport_and_response_errors () =
  List.iter
    (fun (reply, code, message) ->
      let uploads = ref 0 in
      let session =
        Session.create_session
          {
            Session.default_options with
            send = (fun _request -> reply);
            upload_file =
              (fun _upload ->
                incr uploads;
                Error "unexpected upload");
          }
      in
      ignore (configure_encrypted_session session);
      let response =
        dispatch_json session "createSyncGraph"
          "{\"name\":\"Graph\",\"isEncrypted\":false}"
      in
      check_eq (response_error_code response) code;
      check_eq
        (json_string (member "message" (member "error" response)))
        message;
      check_eq !uploads 0)
    [
      (Error "offline", "graph_create_failed", "offline");
      ( Ok (Api.response 503 ""),
        "graph_create_failed",
        "Could not create graph" );
      (Ok (Api.response 403 "denied"), "graph_create_failed", "denied");
      ( Ok (Api.response 201 "{}"),
        "graph_create_failed",
        "Graph creation returned no graph id" );
      ( Ok (Api.response 201 "[]"),
        "graph_create_failed",
        "Graph creation returned no graph id" );
      ( Ok (Api.response 201 "{\"graph-id\":1}"),
        "graph_create_failed",
        "Graph creation returned no graph id" );
    ]

let encrypted_graph_creation_stops_when_key_provisioning_is_unavailable () =
  let uploads = ref 0 in
  let session =
    Session.create_session
      {
        Session.default_options with
        send =
          (fun _request -> Ok (Api.response 201 "{\"graph-id\":\"new-private\"}"));
        upload_file =
          (fun _upload ->
            incr uploads;
            Error "unexpected upload");
      }
  in
  ignore (configure_encrypted_session session);
  check_eq
    (response_error_code
       (dispatch_json session "createSyncGraph"
          "{\"name\":\"Private\",\"isEncrypted\":true}"))
    "graph_key_provision_failed";
  check_eq !uploads 0

let encrypted_graph_creation_stops_after_key_provisioning_failure () =
  let events = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        send =
          (fun _request ->
            events := !events @ [ "create" ];
            Ok (Api.response 201 "{\"graph-id\":\"new-private\"}"));
        provision_graph_key =
          Some
            (fun config ->
              check_eq config.Api.graph_id "new-private";
              check_eq config.graph_name (Some "Private");
              events := !events @ [ "provision" ];
              Error "key storage unavailable");
        upload_file =
          (fun _upload ->
            events := !events @ [ "upload" ];
            Error "unexpected upload");
      }
  in
  ignore (configure_encrypted_session session);
  check_eq
    (response_error_code
       (dispatch_json session "createSyncGraph"
          "{\"name\":\" Private \",\"isEncrypted\":true}"))
    "graph_key_provision_failed";
  check_eq !events [ "create"; "provision" ]

let graph_creation_cleans_up_after_upload_http_failure () =
  let uploaded_path = ref None in
  let session =
    Session.create_session
      {
        Session.default_options with
        send =
          (fun _request -> Ok (Api.response 201 "{\"graph-id\":\"new-plain\"}"));
        upload_file =
          (fun upload ->
            uploaded_path := Some upload.Api.file_path;
            check (Sys.file_exists upload.file_path);
            Ok (Api.response 500 ""));
      }
  in
  ignore (configure_encrypted_session session);
  let response =
    dispatch_json session "createSyncGraph" "{\"name\":\"Plain\",\"isEncrypted\":false}"
  in
  check_eq (response_error_code response) "graph_initial_upload_failed";
  check_eq
    (json_string (member "message" (member "error" response)))
    "Initial snapshot upload failed with HTTP 500";
  match !uploaded_path with
  | Some path -> check (not (Sys.file_exists path))
  | None -> check false

let encrypted_graph_selection_attempts_offline_key_cache () =
  let loaded = ref [] in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some encrypted_graph_catalog);
        load_cached_graph_key =
          Some
            (fun config ->
              loaded := !loaded @ [ config.Api.graph_id ];
              Error "not cached");
        graph_unlocked = Some (fun _graph_id -> false);
      }
  in
  ignore (configure_encrypted_session session);
  let response = dispatch_json session "selectGraph" "encrypted-1" in
  let result = member "result" response in
  check (Json_util.to_bool (member "ok" response));
  check (Json_util.to_bool (member "isGraphEncrypted" result));
  check (not (Json_util.to_bool (member "isGraphUnlocked" result)));
  check_eq !loaded [ "encrypted-1" ]

let encrypted_graph_unlock_forwards_password_and_updates_state () =
  let unlocked = ref false in
  let received = ref None in
  let session =
    Session.create_session
      {
        Session.default_options with
        load_graph_catalog = Some (fun () -> Some encrypted_graph_catalog);
        unlock_graph =
          Some
            (fun _config password ->
              received := Some password;
              unlocked := true;
              Ok ());
        graph_unlocked = Some (fun _graph_id -> !unlocked);
      }
  in
  ignore (configure_encrypted_session session);
  ignore (dispatch_json session "selectGraph" "encrypted-1");
  let response = dispatch_json session "unlockGraph" "correct horse" in
  check (Json_util.to_bool (member "ok" response));
  check
    (Json_util.to_bool (member "isGraphUnlocked" (member "result" response)));
  check_eq !received (Some "correct horse")

let session_rejects_legacy_sync_action () =
  let response =
    Json.from_string
      (Session.call
         (Session.create_session Session.default_options)
         "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"syncPending\"}}")
  in
  check (not (Json_util.to_bool (member "ok" response)));
  check_eq
    (json_string (member "code" (member "error" response)))
    "unknown_action"

let session_without_graph_has_no_due_flashcards () =
  let response =
    Json.from_string
      (Session.call
         (Session.create_session Session.default_options)
         "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"loadFlashcards\",\"payload\":\"1776000000000\"}}")
  in
  check (Json_util.to_bool (member "ok" response));
  check_eq
    (Json.to_string (member "flashcards" (member "result" response)))
    "[]"

let session_restores_cached_graph_name_without_token () =
  let response =
    Json.from_string
      (Session.call
         (Session.create_session Session.default_options)
         "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"http://127.0.0.1:8787\\\",\\\"graphId\\\":\\\"cached-graph\\\",\\\"graphName\\\":\\\"Sync 2\\\",\\\"token\\\":\\\"\\\"}\"}}")
  in
  let result = member "result" response in
  check_eq
    (json_string (member "selectedGraphId" result))
    "cached-graph";
  check_eq (json_string (member "graphName" result)) "Sync 2"

let session_clear_related_exposes_related_blocks () =
  let response =
    Json.from_string
      (Session.call
         (Session.create_session Session.default_options)
         "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"clearRelated\"}}")
  in
  check_eq
    (Json.to_string (member "relatedBlocks" (member "result" response)))
    "[]"

let rpc_routing_validates_before_executing_actions () =
  let calls = ref [] in
  let snapshot () =
    calls := !calls @ [ "snapshot" ];
    "snapshot-result"
  in
  let dispatch action payload =
    calls := !calls @ [ action ];
    match payload with Some value -> value | None -> "no-payload"
  in
  let call request = Rpc.call snapshot dispatch request in
  List.iter
    (fun (request, code, message) ->
      check_eq (call request) (Rpc.failure code message))
    [
      ("{", "invalid_json", "request must be valid JSON");
      ("[]", "invalid_request", "request must be an object");
      ("{}", "invalid_request", "missing field: apiVersion");
      ( "{\"apiVersion\":2}",
        "unsupported_version",
        "only API version 1 is supported" );
      ( "{\"apiVersion\":null}",
        "invalid_request",
        "apiVersion must be an integer" );
      ("{\"apiVersion\":1}", "invalid_request", "missing field: method");
      ( "{\"apiVersion\":1,\"method\":1}",
        "invalid_request",
        "field must be a string: method" );
      ( "{\"apiVersion\":1,\"method\":\"open\"}",
        "invalid_request",
        "missing field: params" );
      ( "{\"apiVersion\":1,\"method\":\"open\",\"params\":null}",
        "invalid_request",
        "params must be an object" );
      ( "{\"apiVersion\":1,\"method\":\"bad\",\"params\":{}}",
        "unknown_method",
        "unknown method: bad" );
      ( "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{}}",
        "invalid_params",
        "missing field: action" );
      ( "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":1}}",
        "invalid_params",
        "field must be a string: payload" );
    ];
  check_eq !calls [];
  check_eq
    (call "{\"apiVersion\":1,\"method\":\"open\",\"params\":{}}")
    "snapshot-result";
  check_eq
    (call "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")
    "snapshot-result";
  check_eq
    (call
       "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":\"hello\"}}")
    "hello";
  check_eq
    (call
       "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"sync\"}}")
    "no-payload";
  check_eq !calls [ "snapshot"; "snapshot"; "send"; "sync" ]

let rpc_routing_keeps_first_fields_and_catches_handler_errors () =
  let snapshot () = "snapshot" in
  let dispatch _action payload =
    match payload with Some value -> value | None -> "nil"
  in
  check_eq
    (Rpc.call snapshot dispatch
       "{\"apiVersion\":1,\"apiVersion\":2,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":\"first\",\"payload\":\"second\"}}")
    "first";
  check_eq
    (Rpc.call snapshot dispatch
       "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"sync\",\"payload\":null}}")
    "nil";
  check_eq
    (Rpc.call
       (fun () -> Json.to_string (Json.from_string "{"))
       dispatch
       "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")
    (Rpc.failure "invalid_json" "request must be valid JSON")

let capture_payload_supports_plain_text_and_validated_json () =
  List.iter
    (fun (payload, expected) ->
      check_eq (Rpc.send_payload payload) (Ok expected))
    [
      (None, ("", None, None));
      (Some "  hello\n", ("hello", None, None));
      (Some " {broken ", ("{broken", None, None));
      (Some " [1] ", ("[1]", None, None));
      (Some "null", ("null", None, None));
      (Some "\"hello\"", ("\"hello\"", None, None));
      ( Some "{\"text\":\" hi \",\"uuid\":\"u\",\"now\":42}",
        ("hi", Some "u", Some 42) );
      ( Some "{\"text\":\" hi \",\"uuid\":null,\"now\":null}",
        ("hi", None, None) );
      ( Some "{\"text\":\"first\",\"text\":\"second\"}",
        ("first", None, None) );
    ];
  List.iter
    (fun (payload, message) ->
      check_eq (Rpc.send_payload (Some payload)) (Error message))
    [
      ("{}", "missing field: text");
      ( "{\"text\":7,\"uuid\":7,\"now\":false}",
        "field must be a string: text" );
      ( "{\"text\":\"hi\",\"uuid\":7,\"now\":false}",
        "field must be a string: uuid" );
      ("{\"text\":\"hi\",\"now\":1.5}", "field must be an integer: now");
    ]

let rpc_response_envelopes_preserve_version_and_error_contract () =
  check_eq
    (Rpc.success (Json.from_string "{\"x\":[1,null]}"))
    "{\"apiVersion\":1,\"ok\":true,\"result\":{\"x\":[1,null]},\"error\":null}";
  check_eq
    (Rpc.failure "invalid" "line\nquoted \"text\"")
    "{\"apiVersion\":1,\"ok\":false,\"result\":null,\"error\":{\"code\":\"invalid\",\"message\":\"line\\nquoted \\\"text\\\"\"}}"

let pending_request_preserves_body_and_upload_wire_fields () =
  let request : Api.api_request =
    {
      method_ = "POST";
      url = "https://example.test/api";
      body = None;
      token = "secret";
    }
  in
  let encode body path headers =
    Rpc.request_json 7 { request with body } path "application/json" headers
  in
  check_eq
    (Json.to_string (encode None None []))
    "{\"id\":7,\"method\":\"POST\",\"url\":\"https://example.test/api\",\"token\":\"secret\",\"contentType\":\"application/json\",\"headers\":{}}";
  List.iter
    (fun body ->
      let encoded = encode (Some body) None [] in
      check_eq (json_string (member "body" encoded)) body;
      check_eq
        (Json.to_string (Json.from_string body))
        (Json.to_string (member "bodyObject" encoded)))
    [ "{\"x\":1}"; "[]"; "null"; "false"; "42"; "\"hello\"" ];
  List.iter
    (fun body ->
      let encoded = encode (Some body) None [] in
      check_eq (json_string (member "body" encoded)) body;
      check_eq (Json.to_string (member "bodyObject" encoded)) "null")
    [ ""; "{"; "raw text" ];
  check_eq
    (Json.to_string
       (Rpc.request_json 7 request (Some "/tmp/a b")
          "application/octet-stream"
          [ ("X-Key", "one"); ("X-Key", "two") ]))
    "{\"id\":7,\"method\":\"POST\",\"url\":\"https://example.test/api\",\"token\":\"secret\",\"contentType\":\"application/octet-stream\",\"headers\":{\"X-Key\":\"one\",\"X-Key\":\"two\"},\"filePath\":\"/tmp/a b\"}"

let toolbar_wire_actions_preserve_all_public_mappings () =
  List.iter
    (fun (wire, action) ->
      check_eq (Rpc.toolbar_action wire) (Ok action))
    [
      ("task", Outliner.Task);
      ("outdent", Outliner.Outdent);
      ("indent", Outliner.Indent);
      ("moveUp", Outliner.Move_up);
      ("moveDown", Outliner.Move_down);
      ("tag", Outliner.Tag_action);
      ("pageReference", Outliner.Page_reference);
      ("camera", Outliner.Camera);
      ("audio", Outliner.Audio);
      ("attachment", Outliner.Attachment);
      ("hideKeyboard", Outliner.Hide_keyboard);
      ("copy", Outliner.Copy);
      ("delete", Outliner.Delete);
      ("copyReference", Outliner.Copy_reference);
      ("copyURL", Outliner.Copy_url);
      ("unselect", Outliner.Unselect);
    ];
  List.iter
    (fun wire ->
      check_eq
        (Rpc.toolbar_action wire)
        (Error "unknown outliner toolbar action"))
    [ "unsupported"; ""; "Task"; "copyUrl" ]

let flashcard_wire_ratings_preserve_values_and_validation () =
  List.iter
    (fun (wire, rating) ->
      check_eq (Rpc.flashcard_rating wire) (Ok rating))
    [
      ("again", Flashcards.Again);
      ("hard", Flashcards.Hard);
      ("good", Flashcards.Good);
      ("easy", Flashcards.Easy);
    ];
  List.iter
    (fun wire ->
      check_eq
        (Rpc.flashcard_rating wire)
        (Error "rating must be again, hard, good, or easy"))
    [ ""; "Good"; "unknown" ]

let outliner_events_decode_navigation_and_editing_payloads () =
  List.iter
    (fun (wire, expected) ->
      check_eq (Rpc.outliner_message wire) (Ok expected))
    [
      ( "{\"type\":\"tapBlock\",\"uuid\":\"block\"}",
        Outliner.Tap_block "block" );
      ( "{\"type\":\"longPressBlock\",\"uuid\":\"block\"}",
        Outliner.Long_press_block "block" );
      ( "{\"type\":\"caretMoved\",\"caretUTF16Offset\":3}",
        Outliner.Caret_moved 3 );
      ("{\"type\":\"returnPressed\"}", Outliner.Return_pressed);
      ( "{\"type\":\"returnPressed\",\"title\":\"Hello\",\"caretUTF16Offset\":2}",
        Outliner.Return_pressed_with_text { title = "Hello"; caret = 2 } );
      ( "{\"type\":\"textChanged\",\"title\":\"New\",\"caretUTF16Offset\":3}",
        Outliner.Text_changed { title = "New"; caret = 3 } );
      ( "{\"type\":\"backspacePressed\",\"selectionLength\":0}",
        Outliner.Backspace_pressed { selection_length = 0 } );
      ( "{\"type\":\"backspacePressed\",\"selectionLength\":2,\"title\":\"Text\"}",
        Outliner.Backspace_pressed_with_text
          { backspace_title = "Text"; backspace_selection_length = 2 } );
      ( "{\"type\":\"toolbar\",\"action\":\"task\"}",
        Outliner.Toolbar Outliner.Task );
      ( "{\"type\":\"chooseAutocomplete\",\"value\":\"page\"}",
        Outliner.Choose_autocomplete "page" );
      ("{\"type\":\"confirmDelete\"}", Outliner.Confirm_delete);
      ("{\"type\":\"saveEditing\"}", Outliner.Save_editing);
      ("{\"type\":\"cancelEditing\"}", Outliner.Cancel_editing);
      ( "{\"type\":\"toggleCollapsed\",\"uuid\":\"block\"}",
        Outliner.Toggle_collapsed "block" );
      ( "{\"type\":\"zoomIn\",\"uuid\":\"block\"}",
        Outliner.Zoom_in "block" );
      ("{\"type\":\"zoomOut\"}", Outliner.Zoom_out);
      ( "{\"type\":\"addRootBlock\",\"uuid\":\"page\"}",
        Outliner.Add_root_block "page" );
    ]

let outliner_event_errors_preserve_wire_validation () =
  List.iter
    (fun (wire, message) ->
      check_eq (Rpc.outliner_message wire) (Error message))
    [
      ("{", "outliner event must be valid JSON");
      ("[]", "outliner event must be an object");
      ("{}", "missing field: type");
      ("{\"type\":1}", "field must be a string: type");
      ("{\"type\":\"unknown\"}", "unknown outliner event type");
      ("{\"type\":\"tapBlock\"}", "missing field: uuid");
      ( "{\"type\":\"caretMoved\",\"caretUTF16Offset\":1.0}",
        "missing integer outliner event field: caretUTF16Offset" );
      ( "{\"type\":\"returnPressed\",\"title\":\"x\"}",
        "returnPressed requires both title and caretUTF16Offset" );
      ( "{\"type\":\"returnPressed\",\"caretUTF16Offset\":1}",
        "returnPressed requires both title and caretUTF16Offset" );
      ( "{\"type\":\"returnPressed\",\"title\":null,\"caretUTF16Offset\":null}",
        "returnPressed requires both title and caretUTF16Offset" );
      ( "{\"type\":\"backspacePressed\"}",
        "missing integer outliner event field: selectionLength" );
      ( "{\"type\":\"backspacePressed\",\"selectionLength\":0,\"title\":null}",
        "backspacePressed title must be a string" );
      ( "{\"type\":\"toolbar\",\"action\":\"bad\"}",
        "unknown outliner toolbar action" );
      ( "{\"type\":\"dropBlocks\",\"targetUuid\":\"x\",\"placement\":\"bad\"}",
        "unknown outliner drop placement" );
      ( "{\"type\":\"setTaskStatus\",\"uuid\":\"x\"}",
        "setTaskStatus requires a status reference" );
    ]

let outliner_drop_and_status_events_preserve_priority () =
  List.iter
    (fun (wire, placement) ->
      check_eq
        (Rpc.outliner_message
           (Printf.sprintf
              "{\"type\":\"dropBlocks\",\"targetUuid\":\"x\",\"placement\":\"%s\"}"
              wire))
        (Ok
           (Outliner.Drop_blocks
              { target_uuid = "x"; placement })))
    [
      ("before", Outliner.Before);
      ("inside", Outliner.Inside);
      ("after", Outliner.After);
    ];
  check_eq
    (Rpc.outliner_message
       "{\"type\":\"setTaskStatus\",\"uuid\":\"x\",\"statusIdent\":\"todo\",\"statusUuid\":7}")
    (Ok
       (Outliner.Set_task_status
          { status_uuid = "x"; status = Ops.Ref_ident "todo" }));
  check_eq
    (Rpc.outliner_message
       "{\"type\":\"setTaskStatus\",\"uuid\":\"x\",\"statusIdent\":null,\"statusUuid\":\"status\"}")
    (Ok
       (Outliner.Set_task_status
          { status_uuid = "x"; status = Ops.Ref_uuid "status" }));
  check_eq
    (Rpc.outliner_message
       "{\"type\":\"setTaskStatus\",\"uuid\":\"x\",\"statusIdent\":7,\"statusUuid\":\"status\"}")
    (Error "field must be a string: statusIdent");
  check_eq
    (Rpc.outliner_message
       "{\"type\":\"tapBlock\",\"uuid\":\"first\",\"uuid\":\"second\"}")
    (Ok (Outliner.Tap_block "first"))

let video_block uuid title = Model.local_block uuid title "page" None 0

let optimistic_intents_preserve_unmodified_block_fields () =
  let source = { (video_block "source" "Before") with sync_status = "synced" } in
  let other = video_block "other" "Other" in
  let rename =
    Ops.Save_title
      { uuid = "source"; expected_title = "Before"; title = "After" }
  in
  let insert =
    Ops.Insert_block
      {
        uuid = "new";
        title = "New";
        page_uuid = "page";
        parent_uuid = "source";
        order = "a1";
        created_at = 42;
      }
  in
  check_eq
    (Rpc.project_outliner_intent [ source; other ] rename)
    [ { source with title = "After" }; other ];
  check_eq (Rpc.project_outliner_intent [] rename) [];
  check_eq
    (Rpc.project_outliner_intent [ source ] insert)
    [
      source;
      {
        (Model.local_block "new" "New" "page" (Some "source") 42) with
        Model.order = Some "a1";
      };
    ]

let optimistic_assets_replace_in_place_and_preserve_local_path () =
  let source =
    { (video_block "asset" "Draft") with local_path = Some "/local/image" }
  in
  let other = video_block "other" "Other" in
  let intent =
    Ops.Create_asset
      {
        uuid = "asset";
        title = "Image";
        page_uuid = "page";
        parent_uuid = "parent";
        order = "a2";
        created_at = 7;
        asset_type = "image/png";
        asset_size = 12;
        asset_checksum = "hash";
        transcript = None;
      }
  in
  let asset =
    {
      (Model.local_block "asset" "Image" "page" (Some "parent") 7) with
      Model.order = Some "a2";
      is_asset = true;
      asset_type = Some "image/png";
      asset_size = Some 12;
      asset_checksum = Some "hash";
    }
  in
  check_eq
    (Rpc.project_outliner_intent [ source; other ] intent)
    [ { asset with local_path = Some "/local/image" }; other ];
  check_eq (Rpc.project_outliner_intent [ other ] intent) [ other; asset ]

let optimistic_splits_preserve_source_location_and_ignore_missing_source () =
  let source =
    {
      (video_block "source" "BeforeAfter") with
      parent_id = Some "parent";
      order = Some "a0";
      sync_status = "synced";
    }
  in
  let intent =
    Ops.Split_block
      {
        uuid = "source";
        expected_title = "BeforeAfter";
        before = "Before";
        after = "After";
        new_uuid = "new";
        new_order = "a1";
        created_at = 10;
      }
  in
  check_eq (Rpc.project_outliner_intent [] intent) [];
  check_eq
    (Rpc.project_outliner_intent [ source ] intent)
    [
      { source with title = "Before" };
      {
        (Model.local_block "new" "After" "page" (Some "parent") 10) with
        Model.order = Some "a1";
      };
    ]

let optimistic_merges_use_explicit_title_or_concatenate_without_separator () =
  let previous =
    { (video_block "previous" "Before") with sync_status = "synced" }
  in
  let source = video_block "source" "After" in
  let payload : Ops.pending_merge =
    {
      uuid = "source";
      expected_title = "After";
      title = "After";
      previous_uuid = "previous";
      expected_previous_title = "Before";
      merged_title = None;
    }
  in
  check_eq
    (Rpc.project_outliner_intent [ previous; source ]
       (Ops.Merge_backward payload))
    [ { previous with title = "BeforeAfter"; sync_status = "pending" } ];
  check_eq
    (Rpc.project_outliner_intent [ previous; source ]
       (Ops.Merge_backward { payload with merged_title = Some "" }))
    [ { previous with title = ""; sync_status = "pending" } ];
  check_eq
    (Rpc.project_outliner_intent [ source ] (Ops.Merge_backward payload))
    []

let optimistic_moves_apply_in_order_and_deletes_only_remove_specified_ids () =
  let source = video_block "source" "Source" in
  let child =
    { (video_block "child" "Child") with parent_id = Some "source" }
  in
  let move : Ops.pending_move =
    { uuid = "source"; page_uuid = "new-page"; parent_uuid = "parent"; order = "a1" }
  in
  let expected =
    {
      source with
      page_id = "new-page";
      parent_id = Some "parent";
      order = Some "a1";
      sync_status = "pending";
    }
  in
  check_eq
    (Rpc.project_outliner_intent [ source; child ] (Ops.Move_block move))
    [ expected; child ];
  check_eq
    (Rpc.project_outliner_intent [ source; child ]
       (Ops.Move_blocks { moves = [ move; { move with order = "a2" } ] }))
    [ { expected with order = Some "a2" }; child ];
  check_eq
    (Rpc.project_outliner_intent [ source; child ]
       (Ops.Delete_blocks { uuids = [ "source"; "missing" ] }))
    [ child ]

let optimistic_status_projection_handles_builtins_custom_refs_and_clearing () =
  let source = { (video_block "source" "Task") with sync_status = "synced" } in
  let property : Ops.pending_property =
    {
      uuid = "source";
      attr = "logseq.property/status";
      expected = None;
      value = None;
    }
  in
  List.iter
    (fun (ident, uuid, title) ->
      let status : Model.status =
        {
          uuid;
          title;
          ident = Some ident;
          icon_type = None;
          icon_id = None;
          icon_color = None;
        }
      in
      check_eq
        (Rpc.project_outliner_intent [ source ]
           (Ops.Set_property
              { property with value = Some (Ops.Ref_ident ident) }))
        [ { source with status = Some status; sync_status = "pending" } ])
    [
      ("logseq.property/status.backlog", "backlog", "Backlog");
      ("logseq.property/status.todo", "todo", "Todo");
      ("logseq.property/status.doing", "doing", "Doing");
      ("logseq.property/status.in-review", "in-review", "In Review");
      ("logseq.property/status.done", "done", "Done");
      ("logseq.property/status.canceled", "canceled", "Canceled");
      ("custom", "custom", "custom");
    ];
  let status : Model.status =
    {
      uuid = "custom-id";
      title = "custom-id";
      ident = None;
      icon_type = None;
      icon_id = None;
      icon_color = None;
    }
  in
  check_eq
    (Rpc.project_outliner_intent [ source ]
       (Ops.Set_property
          { property with value = Some (Ops.Ref_uuid "custom-id") }))
    [ { source with status = Some status; sync_status = "pending" } ];
  let cleared = [ { source with status = None; sync_status = "pending" } ] in
  check_eq
    (Rpc.project_outliner_intent [ source ] (Ops.Set_property property))
    cleared;
  check_eq
    (Rpc.project_outliner_intent [ source ]
       (Ops.Set_property
          { property with value = Some (Ops.String_value "not-a-reference") }))
    cleared;
  check_eq
    (Rpc.project_outliner_intent [ source ]
       (Ops.Set_property { property with attr = "other" }))
    [ source ];
  check_eq
    (Rpc.project_outliner_intent [ source ]
       (Ops.Create_page { uuid = "page"; title = "Page"; created_at = 0 }))
    [ source ]

let optimistic_overlay_preserves_draft_fields_and_refreshes_live_metadata () =
  let draft =
    {
      (video_block "a" "Draft") with
      parent_id = Some "draft-parent";
      order = Some "a1";
      created_at = 1;
    }
  in
  let summary : Model.entity_summary = { uuid = "ref"; title = "Reference" } in
  let status : Model.status =
    {
      uuid = "done";
      title = "Done";
      ident = None;
      icon_type = None;
      icon_id = None;
      icon_color = None;
    }
  in
  let live =
    {
      (video_block "a" "Server") with
      parent_id = Some "server-parent";
      order = Some "z9";
      created_at = 2;
      updated_at = 99;
      sync_status = "synced";
      tags = [ summary ];
      references = [ summary ];
      breadcrumbs = [ summary ];
      status = Some status;
      is_asset = true;
      asset_type = Some "jpg";
      asset_size = Some 42;
      asset_checksum = Some "checksum";
      local_path = Some "/tmp/image";
      journal = Some ("Today", 20260916);
    }
  in
  let expected =
    {
      live with
      title = "Draft";
      parent_id = Some "draft-parent";
      order = Some "a1";
      created_at = 1;
    }
  in
  check_eq (Rpc.merge_live_block_metadata draft live) expected;
  check_eq
    (Rpc.page_blocks_with_optimistic_overlay (Some [ draft ]) true "page"
       [ live ])
    [ expected ]

let optimistic_overlay_only_applies_while_editing_and_keeps_cached_membership () =
  let draft = video_block "a" "Draft" in
  let missing = video_block "missing" "Offline" in
  let other = { (video_block "other" "Other") with page_id = "other-page" } in
  let live = video_block "a" "Server" in
  let newer = { live with updated_at = 2 } in
  let added = video_block "new" "New" in
  let cached = Some [ missing; other; draft ] in
  check_eq
    (Rpc.page_blocks_with_optimistic_overlay cached true "page"
       [ live; newer; added ])
    [ missing; { draft with updated_at = 2 } ];
  check_eq
    (Rpc.page_blocks_with_optimistic_overlay cached false "page"
       [ live; added ])
    [ live; added ];
  check_eq
    (Rpc.page_blocks_with_optimistic_overlay None true "page" [ live ])
    [ live ];
  check_eq
    (Rpc.page_blocks_with_optimistic_overlay (Some []) true "page" [ live ])
    []

let outliner_rows_preserve_hierarchy_video_targets_and_serializer () =
  let video = video_block "video" "{{youtube dQw4w9WgXcQ}}" in
  let child =
    {
      (video_block "child" "{{youtube-timestamp 00:10}}") with
      parent_id = Some "video";
    }
  in
  let context = Outliner.context [ video; child ] [] [] in
  let seen = ref [] in
  let serialize (block : Model.block) =
    seen := !seen @ [ block.uuid ];
    `String block.uuid
  in
  let encode state = Json.to_string (Rpc.outliner_rows_json serialize context state) in
  check_eq
    (encode Outliner.empty)
    "[{\"block\":\"video\",\"depth\":0,\"hasChildren\":true,\"isCollapsed\":false},{\"block\":\"child\",\"depth\":1,\"hasChildren\":false,\"isCollapsed\":false,\"youtubeTargetURL\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}]";
  check_eq !seen [ "video"; "child" ];
  seen := [];
  check_eq
    (encode
       {
         Outliner.empty with
         collapsed = Outliner.Sset.of_list [ "video" ];
       })
    "[{\"block\":\"video\",\"depth\":0,\"hasChildren\":true,\"isCollapsed\":true}]";
  check_eq !seen [ "video" ]

let outliner_candidate_json_preserves_filtering_and_no_request () =
  let candidate : Outliner.outliner_candidate =
    { label = "Alpha"; value = "page" }
  in
  let context = Outliner.context [] [ candidate ] [] in
  let state =
    {
      Outliner.empty with
      autocomplete = Some { kind = Outliner.Node; query = "alp" };
    }
  in
  check_eq
    (Json.to_string (Rpc.outliner_candidates_json context Outliner.empty))
    "[]";
  check_eq
    (Json.to_string (Rpc.outliner_candidates_json context state))
    "[{\"label\":\"Alpha\",\"value\":\"page\"},{\"label\":\"New page: alp\",\"value\":\"alp\"}]"

let json_field value key = Json.to_string (member key value)

let graph_json_keeps_null_schema_and_readiness_flags () =
  let graph : Api.api_graph =
    {
      id = "graph";
      name = "Graph";
      schema_version = None;
      role = None;
      e2ee = false;
      ready = true;
    }
  in
  check_eq
    (Json.to_string (Rpc.graph_json graph))
    "{\"id\":\"graph\",\"name\":\"Graph\",\"schemaVersion\":null,\"isEncrypted\":false,\"isReady\":true}";
  check_eq
    (Json.to_string
       (Rpc.graph_json
          { graph with schema_version = Some "v1"; e2ee = true; ready = false }))
    "{\"id\":\"graph\",\"name\":\"Graph\",\"schemaVersion\":\"v1\",\"isEncrypted\":true,\"isReady\":false}"

let search_json_keeps_page_and_breadcrumb_order () =
  let parent : Model.entity_summary = { uuid = "parent"; title = "Parent" } in
  let page : Model.entity_summary = { uuid = "page"; title = "Page" } in
  let hit : Search.indexed_search_hit =
    {
      uuid = "hit";
      title = "Hit";
      is_page = false;
      page = None;
      breadcrumbs = [];
    }
  in
  check_eq
    (Json.to_string (Rpc.search_hit_json hit))
    "{\"uuid\":\"hit\",\"title\":\"Hit\",\"isPage\":false,\"page\":null,\"breadcrumbs\":[]}";
  check_eq
    (Json.to_string
       (Rpc.search_hit_json
          {
            hit with
            is_page = true;
            page = Some page;
            breadcrumbs = [ parent; page ];
          }))
    "{\"uuid\":\"hit\",\"title\":\"Hit\",\"isPage\":true,\"page\":{\"uuid\":\"page\",\"title\":\"Page\"},\"breadcrumbs\":[{\"uuid\":\"parent\",\"title\":\"Parent\"},{\"uuid\":\"page\",\"title\":\"Page\"}]}"

let flashcard_json_keeps_counters_state_and_children () =
  List.iter
    (fun (state, wire) ->
      let card =
        { (Flashcards.new_card 123) with reps = 7; lapses = 2; state }
      in
      let due : Flashcards.due_card =
        {
          block = video_block "card" "Question";
          children = [ video_block "child" "Answer" ];
          card;
        }
      in
      let encoded = Rpc.flashcard_json due in
      check_eq (json_field encoded "due") "123";
      check_eq (json_field encoded "repetitions") "7";
      check_eq (json_field encoded "lapses") "2";
      check_eq (json_field encoded "state") ("\"" ^ wire ^ "\"");
      check_eq (json_field (member "block" encoded) "uuid") "\"card\"";
      let child = Json.to_string (Rpc.block_json (video_block "child" "Answer")) in
      check_eq (json_field encoded "children") ("[" ^ child ^ "]"))
    [
      (Flashcards.New, "new");
      (Flashcards.Learning, "learning");
      (Flashcards.Review, "review");
      (Flashcards.Relearning, "relearning");
    ]

let block_json_publishes_resolved_markup_and_omits_absent_fields () =
  let block =
    {
      (video_block "source" "See [[target]]") with
      references =
        [
          ({ uuid = "target"; title = "Target block" } : Model.entity_summary);
        ];
    }
  in
  let result = Rpc.block_json block in
  check_eq
    (json_field result "markup")
    "[{\"type\":\"text\",\"text\":\"See \"},{\"type\":\"nodeReference\",\"uuid\":\"target\",\"title\":\"Target block\"}]";
  check_eq
    (Json_util.keys result)
    [
      "uuid";
      "title";
      "displayTitle";
      "pageId";
      "createdAt";
      "updatedAt";
      "syncStatus";
      "isAsset";
      "tags";
      "references";
      "breadcrumbs";
      "markup";
    ]

let block_json_preserves_asset_and_journal_fields () =
  let block =
    {
      (video_block "asset" "Photo") with
      order = Some "a1";
      parent_id = Some "parent";
      is_asset = true;
      asset_type = Some "png";
      asset_size = Some 123;
      asset_checksum = Some "checksum";
      local_path = Some "/tmp/photo.png";
      journal = Some ("Journal", 20260816);
    }
  in
  let result = Rpc.visible_block_json block in
  List.iter
    (fun (key, expected) -> check_eq (json_field result key) expected)
    [
      ("order", "\"a1\"");
      ("parentId", "\"parent\"");
      ("isAsset", "true");
      ("assetType", "\"png\"");
      ("assetSize", "123");
      ("assetChecksum", "\"checksum\"");
      ("localPath", "\"/tmp/photo.png\"");
      ("journalTitle", "\"Journal\"");
      ("journalDay", "20260816");
    ];
  check_eq
    (Json.to_string (Rpc.block_json (video_block "plain" "Plain")))
    (Json.to_string (Rpc.visible_block_json (video_block "plain" "Plain")))

let status_json_requires_both_icon_type_and_id () =
  let status : Model.status =
    {
      uuid = "todo";
      title = "Todo";
      ident = None;
      icon_type = None;
      icon_id = None;
      icon_color = None;
    }
  in
  check_eq
    (Json.to_string (Rpc.status_response_json status))
    "{\"uuid\":\"todo\",\"title\":\"Todo\"}";
  check_eq
    (Json.to_string
       (Rpc.status_response_json
          {
            status with
            icon_type = Some "emoji";
            icon_color = Some "red";
          }))
    "{\"uuid\":\"todo\",\"title\":\"Todo\"}";
  let rich =
    {
      status with
      ident = Some "status.todo";
      icon_type = Some "emoji";
      icon_id = Some "check";
      icon_color = Some "red";
    }
  in
  check_eq
    (Json.to_string (Rpc.status_response_json rich))
    "{\"uuid\":\"todo\",\"title\":\"Todo\",\"ident\":\"status.todo\",\"icon\":{\"type\":\"emoji\",\"id\":\"check\",\"color\":\"red\"}}"

let empty_outliner_state_keeps_null_and_empty_wire_fields () =
  check_eq
    (Json.to_string (Rpc.outliner_state_json Outliner.empty))
    "{\"editing\":null,\"selectedBlockIds\":[],\"collapsedBlockIds\":[],\"zoomedBlockIds\":[],\"autocomplete\":null}"

let outliner_state_serializes_drafts_and_orders_identifiers () =
  List.iter
    (fun (kind, wire_kind) ->
      let state =
        {
          Outliner.empty with
          editing =
            Some
              {
                uuid = "block";
                content_uuid = "block";
                expected_title = "Old";
                title = "New";
                caret = 2;
              };
          selected = Outliner.Sset.of_list [ "z"; "a" ];
          collapsed = Outliner.Sset.of_list [ "y"; "b" ];
          zoomed = [ "outer"; "inner" ];
          autocomplete = Some { kind; query = "query" };
        }
      in
      check_eq
        (Json.to_string (Rpc.outliner_state_json state))
        ("{\"editing\":{\"uuid\":\"block\",\"title\":\"New\",\"caretUTF16Offset\":2},"
         ^ "\"selectedBlockIds\":[\"a\",\"z\"],\"collapsedBlockIds\":[\"b\",\"y\"],"
         ^ "\"zoomedBlockIds\":[\"outer\",\"inner\"],\"autocomplete\":{\"kind\":\""
         ^ wire_kind ^ "\",\"query\":\"query\"}}"))
    [
      (Outliner.Node, "node");
      (Outliner.Tag, "tag");
      (Outliner.Property, "property");
    ]

let platform_commands_preserve_their_json_wire_format () =
  List.iter
    (fun (command, expected) ->
      check_eq (Json.to_string (Rpc.outliner_command_json command)) expected)
    [
      ( Effects.Platform_haptic Outliner.Selection,
        "{\"type\":\"haptic\",\"style\":\"selection\"}" );
      ( Effects.Platform_haptic Outliner.Impact,
        "{\"type\":\"haptic\",\"style\":\"impact\"}" );
      (Effects.Focus_block "block", "{\"type\":\"focusBlock\",\"uuid\":\"block\"}");
      ( Effects.Confirm_delete [ "first"; "second" ],
        "{\"type\":\"confirmDelete\",\"uuids\":[\"first\",\"second\"]}" );
      ( Effects.Set_clipboard_text "a\nb",
        "{\"type\":\"setClipboardText\",\"text\":\"a\\nb\"}" );
      ( Effects.Set_clipboard_references [ "x"; "x" ],
        "{\"type\":\"setClipboardReferences\",\"uuids\":[\"x\",\"x\"]}" );
      ( Effects.Set_clipboard_urls [],
        "{\"type\":\"setClipboardURLs\",\"uuids\":[]}" );
      ( Effects.Platform_pick_attachment "x",
        "{\"type\":\"pickAttachment\",\"uuid\":\"x\"}" );
      (Effects.Platform_take_photo "x", "{\"type\":\"takePhoto\",\"uuid\":\"x\"}");
      ( Effects.Platform_record_audio "x",
        "{\"type\":\"recordAudio\",\"uuid\":\"x\"}" );
    ]

let youtube_timestamps_follow_the_most_recent_video_across_blocks () =
  check_eq
    (Rpc.youtube_target_urls
       [
         video_block "video" "{{youtube dQw4w9WgXcQ}}";
         video_block "time" "{{youtube-timestamp 01:23}}";
       ])
    [ ("time", "https://www.youtube.com/watch?v=dQw4w9WgXcQ") ];
  check_eq
    (Rpc.youtube_target_urls
       [ video_block "time" "{{youtube-timestamp 01:23}}" ])
    [];
  check_eq (Rpc.youtube_target_urls []) [];
  check_eq
    (Rpc.youtube_target_urls
       [
         video_block "video" "{{youtube dQw4w9WgXcQ}}";
         video_block "first" "{{youtube-timestamp 00:10}}";
         video_block "other" "{{youtube abcdefghijk}}";
         video_block "second" "{{youtube-timestamp 00:20}}";
       ])
    [
      ("first", "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
      ("second", "https://www.youtube.com/watch?v=abcdefghijk");
    ]

let youtube_targets_ignore_other_videos_and_preserve_original_url () =
  check_eq
    (Rpc.youtube_target_urls
       [
         video_block "video" "{{video https://YouTu.Be/abcdefghijk}}";
         video_block "other" "{{vimeo 12345}}";
         video_block "time" "{{youtube-timestamp 00:10}}";
       ])
    [ ("time", "https://YouTu.Be/abcdefghijk") ];
  check_eq
    (Rpc.youtube_target_urls
       [
         video_block "other" "{{vimeo 12345}}";
         video_block "time" "{{youtube-timestamp 00:10}}";
       ])
    []

let mobile_page_projection_sends_only_32_contents_and_hydrates_distant_rows () =
  let page : Model.entity_summary = { uuid = "large-page"; title = "Large page" } in
  let blocks = List.init 10_000 (fun index ->
    { (Model.local_block ("row-" ^ string_of_int index) ("Block " ^ string_of_int index) page.uuid None 1) with
      Model.parent_id = Some (if index mod 4 = 0 then page.uuid else "row-" ^ string_of_int (index - 1));
      order = Some (Printf.sprintf "a%06d" index) }) in
  let session = Session.create_session { Session.default_options with
    outliner_projection_limit = Some 32;
    graph_sidebar_pages = Some (fun () -> Some { Graph.favorites = [page]; recent_pages = [] });
    graph_page_blocks = Some (fun _ -> Some blocks) } in
  let response = dispatch_json session "selectPage" page.uuid in
  let result = response_result response in
  let rows = json_items "outlinerRows" result in
  check_eq (List.length rows) 10_000;
  let complete = List.filter (fun row -> member "isShell" (member "block" row) <> `Bool true) rows in
  check_eq ~msg:"the initial projection encodes only the first viewport's contents" (List.length complete) 32;
  check_eq (List.length (json_items "blocks" result)) 32;
  check ~msg:"the response contains compact topology instead of two complete page copies"
    (String.length (Json.to_string response) < 2_500_000);
  let last = List.nth rows 9_999 in
  check_eq (member "depth" last) (`Int 3);
  check_eq ~msg:"compact rows retain the timestamps required by native snapshot consumers"
    (member "createdAt" (member "block" last)) (`Int 1);
  check_eq (member "updatedAt" (member "block" last)) (`Int 1);
  let hydrated = response_result (dispatch_json session "hydrateOutlinerRows" "[\"row-9999\",\"row-9998\"]") in
  check_eq (member "isOutlinerContentPatch" hydrated) (`Bool true);
  check_eq (List.map (fun value -> member "title" value) (json_items "hydratedBlocks" hydrated))
    [`String "Block 9999"; `String "Block 9998"]

let journal_refresh_keeps_the_edited_page_beyond_the_launch_window () =
  let page : Model.entity_summary = { uuid = "journal-page"; title = "Oct 22nd, 2026" } in
  let orders = Fractional.n_between None None 500 |> Result.get_ok |> Array.of_list in
  let projected = ref (List.init 500 (fun index ->
    { (Model.local_block ("row-" ^ string_of_int index) ("Block " ^ string_of_int index)
         page.uuid (Some page.uuid) 1) with
      Model.order = Some orders.(index); journal = Some (page.title, 20261022) })) in
  let first_window () = List.filteri (fun index _ -> index < 32) !projected in
  let session = configure_plain_session (Session.create_session {
    Session.default_options with
    outliner_projection_limit = Some 32;
    sync_cursor = Some (fun () -> Some 5);
    graph_blocks = Some (fun () -> Some (first_window ()));
    graph_page_blocks = Some (fun _ -> Some !projected);
    graph_node_destination = Some (fun _ -> Some (page, true));
    stage_operation = Some (fun operation ->
      projected := Rpc.project_outliner_intent !projected operation.Ops.intent; Ok ());
    prepare_operation = Some prepare_operation;
  }) in
  let snapshot () = response_result (Json.from_string (Session.call session
    {|{"apiVersion":1,"method":"snapshot","params":{}}|})) in
  check_eq ~msg:"launch still hydrates only its bounded window"
    (List.length (json_items "outlinerRows" (snapshot ()))) 32;
  ignore (outliner_block_event session "tapBlock" "row-0");
  let active = ref "row-0" in
  for insertion = 1 to 35 do
    let result = outliner_event session (Json.to_string (`Assoc [
      "type", `String "returnPressed"; "uuid", `String !active;
      "title", `String "Block 0"; "caretUTF16Offset", `Int 0])) in
    active := editing_uuid result;
    if insertion mod 5 = 0 then begin
      let refreshed = snapshot () in
      let rows = json_items "outlinerRows" refreshed in
      check_eq ~msg:"a background refresh must retain the complete edited page topology"
        (List.length rows) (500 + insertion);
      check ~msg:"the active editor must remain in the refreshed rows"
        (List.exists (fun row -> member "uuid" (member "block" row) = `String !active) rows);
      check_eq (editing_uuid refreshed) !active
    end
  done;
  projected := List.map (fun (block : Model.block) ->
    if block.uuid = "row-1" then { block with title = "Remote update" } else block) !projected;
  ignore (snapshot ());
  let hydrated = response_result (dispatch_json session "hydrateOutlinerRows" "[\"row-1\"]") in
  check_eq ~msg:"retaining the edited page must still read current authoritative data"
    (member "title" (List.hd (json_items "hydratedBlocks" hydrated))) (`String "Remote update")

let mobile_reference_hydration_preserves_ancestry () =
  List.iter (fun node_route ->
    let page : Model.entity_summary = { uuid = "source-page"; title = "Source page" } in
    let parent : Model.entity_summary = { uuid = "parent"; title = "Parent block" } in
    let body = List.init 40 (fun index ->
      { (Model.local_block ("reference-" ^ string_of_int index) "References its own page" page.uuid None 1) with
        Model.parent_id = Some page.uuid; order = Some (Printf.sprintf "a%06d" index) }) in
    let references = List.map (fun (block : Model.block) ->
      { block with breadcrumbs = [page; parent] }) body in
    let session = Session.create_session { Session.default_options with
      outliner_projection_limit = Some 32;
      graph_sidebar_pages = Some (fun () -> Some { Graph.favorites = [page]; recent_pages = [] });
      graph_node_destination = Some (fun _ -> Some (page, false));
      graph_page_blocks = Some (fun _ -> Some body);
      graph_node_references = Some (fun _ -> Some references) } in
    ignore (response_result (dispatch_json session "selectPage" page.uuid));
    if node_route then ignore (response_result (dispatch_json session "openNode" "{\"uuid\":\"source-page\"}"));
    let loaded = response_result (dispatch_json session "loadPageReferences" page.uuid) in
    check_eq ~msg:"the distant reference starts as a compact shell"
      (member "isShell" (List.nth (json_items "referenceBlocks" loaded) 39)) (`Bool true);
    let hydrated = response_result (dispatch_json session "hydrateOutlinerRows" "[\"reference-39\"]") in
    let reference = List.hd (json_items "hydratedBlocks" hydrated) in
    check_eq ~msg:"hydrating a shared body/reference block retains clickable ancestry"
      (List.map (member "uuid") (json_items "breadcrumbs" reference))
      [`String page.uuid; `String parent.uuid]
  ) [false; true]

let snapshot_dispatch session action payload =
  Json.from_string (Session.call session (Json.to_string (`Assoc [
    "apiVersion", `Int 1; "method", `String "dispatch";
    "params", `Assoc ["action", `String action; "payload", `String payload;
      "projection", `String "snapshot"]])))

let snapshot_projection_replaces_native_patch_reduction () =
  let projected = ref [synced_block "first" "First"; synced_block "second" "Second"] in
  let session = configure_plain_session (Session.create_session {
    Session.default_options with
    sync_cursor = Some (fun () -> Some 91);
    graph_blocks = Some (fun () -> Some !projected);
    stage_operation = Some (fun operation ->
      (match operation.Ops.intent with
       | Ops.Save_title change -> projected := List.map (fun (block : Model.block) ->
           if block.uuid = change.uuid then {block with title = change.title} else block) !projected
       | Ops.Delete_blocks change -> projected := List.filter (fun (block : Model.block) ->
           not (List.mem block.uuid change.uuids)) !projected
       | _ -> ()); Ok ());
    prepare_operation = Some prepare_operation;
  }) in
  let dispatch event = response_result (snapshot_dispatch session "outlinerEvent" event) in
  let check_full result =
    check_eq (member "isOutlinerPatch" result) (`Bool false);
    check_eq (member "isPendingSyncPatch" result) `Null;
    check_eq (member "selectedGraphId" result) (`String "plain-1");
    check_eq (List.length (json_items "outlinerRows" result)) (List.length !projected) in
  let tapped = dispatch {|{"type":"tapBlock","uuid":"first"}|} in
  check_full tapped;
  check_eq (editing_uuid tapped) "first";
  ignore (dispatch {|{"type":"textChanged","title":"After","caretUTF16Offset":5}|});
  let saved = dispatch {|{"type":"saveEditing"}|} in
  check_full saved;
  check_eq (member "title" (List.hd (json_items "blocks" saved))) (`String "After");
  ignore (dispatch {|{"type":"cancelEditing"}|});
  ignore (dispatch {|{"type":"longPressBlock","uuid":"first"}|});
  ignore (dispatch {|{"type":"toolbar","action":"delete"}|});
  let deleted = dispatch {|{"type":"confirmDelete"}|} in
  check_full deleted;
  check_eq (List.map (member "uuid") (json_items "blocks" deleted)) [`String "second"];
  check_eq (json_items "selectedBlockIds" (member "outlinerState" deleted)) [];
  let pending = response_result (snapshot_dispatch session "beginPendingSync" "") in
  check_full pending;
  check_eq (List.map (member "uuid") (json_items "blocks" pending)) [`String "second"];
  check (member "pendingSyncRequest" pending <> `Null);
  let failure = snapshot_dispatch session "unknown" "" in
  check_eq (response_error_code failure) "unknown_action"

let snapshot_projection_keeps_interactive_patches_compact () =
  let session = Session.create_session {Session.default_options with
    graph_blocks = Some (fun () -> Some [synced_block "first" "First"; synced_block "second" "Second"])} in
  let tapped = outliner_event session {|{"type":"tapBlock","uuid":"first"}|} in
  check_eq (member "isOutlinerPatch" tapped) (`Bool true);
  check_eq (json_items "blocks" tapped) [];
  check_eq (json_items "outlinerRows" tapped) []

let forced_snapshot_import_is_atomic_with_editing () =
  let imported = ref 0 in
  let session = Session.create_session {Session.default_options with
    graph_blocks = Some (fun () -> Some [synced_block "first" "First"]);
    import_snapshot = Some (fun _ -> incr imported; Ok ())} in
  ignore (outliner_event session {|{"type":"tapBlock","uuid":"first"}|});
  let payload = {|{"graphId":"plain-1","forceSnapshot":true}|} in
  let deferred = dispatch_json session "importSnapshot" payload in
  check_eq ~msg:"editing is checked inside the serialized core before storage replacement" !imported 0;
  check_eq (response_error_code deferred) "snapshot_deferred";
  ignore (outliner_event session {|{"type":"cancelEditing"}|});
  ignore (response_result (dispatch_json session "importSnapshot" payload));
  check_eq !imported 1

let forced_snapshot_import_rejects_a_changed_graph () =
  let imported = ref 0 in
  let session = configure_plain_session (Session.create_session {Session.default_options with
    import_snapshot = Some (fun _ -> incr imported; Ok ())}) in
  let response = dispatch_json session "importSnapshot" {|{"graphId":"previous-graph","forceSnapshot":true}|} in
  check_eq ~msg:"a late download cannot switch the graph back" !imported 0;
  check_eq (response_error_code response) "graph_changed"

let cases =
  [
    case "search results are loaded in bounded pages" search_results_are_loaded_in_bounded_pages;
    case "idle sync recovery resets after a healthy pull" shared_sync_driver_idle_recovery_resets_after_a_healthy_pull;
    case "forced snapshot import rejects a changed graph" forced_snapshot_import_rejects_a_changed_graph;
    case "snapshot projection replaces native patch reduction" snapshot_projection_replaces_native_patch_reduction;
    case "snapshot projection keeps interactive patches compact" snapshot_projection_keeps_interactive_patches_compact;
    case "forced snapshot import is atomic with editing" forced_snapshot_import_is_atomic_with_editing;
    case "shared pending error summary preserves unicode" shared_pending_error_summary_preserves_unicode;
    case "shared pending retry preserves uploads and bounds attempts" shared_pending_retry_preserves_upload_and_bounds_attempts;
    case "shared pending retry keeps semantic transaction identity" shared_pending_retry_keeps_semantic_transaction_identity;
    case "shared pending retry rejects raw upload conflicts" shared_pending_retry_rejects_raw_upload_conflicts;
    case "shared pending retry reports transaction rejection" shared_pending_retry_reports_transaction_rejection;
    case "shared pending retry cancellation ignores late results" shared_pending_retry_cancellation_cleans_once_and_ignores_late_results;
    case "shared pending retry graph changes discard old transport" shared_pending_retry_graph_changes_discard_old_transport;
 case "shared sync driver bounds backoff and rejects reconfigured events" shared_sync_driver_bounds_backoff_and_rejects_reconfigured_events;
    case "shared sync driver handles missing cursor and network changes" shared_sync_driver_handles_missing_cursor_and_network_changes;
 case "shared sync driver owns pull protocol and notification coalescing" shared_sync_driver_owns_pull_protocol_and_notification_coalescing;
    case "shared sync driver scopes events and controls reconnect" shared_sync_driver_scopes_events_and_controls_reconnect;
    case "shared sync driver snapshot recovery is explicit and edit safe" shared_sync_driver_snapshot_recovery_is_explicit_and_edit_safe;
    case "shared sync driver reports malformed frames and cancels without retry" shared_sync_driver_reports_malformed_frames_and_cancels_without_retry;
 case "mobile 10k page projection bounds content and hydrates distant rows" mobile_page_projection_sends_only_32_contents_and_hydrates_distant_rows;
 case "journal refresh keeps the edited page beyond the launch window" journal_refresh_keeps_the_edited_page_beyond_the_launch_window;
 case "mobile reference hydration preserves ancestry" mobile_reference_hydration_preserves_ancestry;
    case "semantic completion preserves error and status precedence"
      semantic_completion_preserves_error_and_status_precedence;
    case "required string lists preserve order and validate every item"
      required_string_lists_preserve_order_and_validate_every_item;
    case "move payloads preserve order and first validation error"
      move_payloads_preserve_order_and_first_validation_error;
    case "status payload preserves validation and optional fields"
      status_payload_preserves_validation_and_optional_fields;
    case "status reference prefers nonblank ident without trimming it"
      status_reference_prefers_nonblank_ident_without_trimming_it;
    case "journal identifiers and titles preserve wire format"
      journal_identifiers_and_titles_preserve_wire_format;
    case "pending version compares content and asset identity"
      pending_version_compares_content_and_asset_identity;
    case "structural events preserve source and ignore other event types"
      structural_events_preserve_source_and_ignore_other_event_types;
    case "authoritative reconciliation preserves newer local edits"
      authoritative_reconciliation_preserves_newer_local_edits;
    case "node navigation preserves independent projections and editing"
      node_navigation_preserves_independent_projections_and_editing;
    case "search block reveals page and zoom has ancestry" search_block_reveals_page_and_zoom_has_ancestry;
    case "graph assets download and cache binary files" graph_assets_download_and_cache_binary_files;
    case "mobile page references are deferred" mobile_page_references_are_deferred;
    case "sidebar tag selection projects objects and linked references"
      sidebar_tag_selection_projects_objects_and_linked_references;
    case "favorite blocks select the root subtree" favorite_blocks_select_the_root_subtree;
    case "sidebar page selection projects references without node routes"
      sidebar_page_selection_projects_references_without_node_routes;
    case "search projects page context and clears blank queries"
      search_projects_page_context_and_clears_blank_queries;
    case "node navigation resolves projected pages and blocks"
      node_navigation_resolves_projected_pages_and_blocks;
    case "offline node navigation uses pending projection and journal title"
      offline_node_navigation_uses_pending_projection_and_journal_title;
    case "loading older journals expands core owned window"
      loading_older_journals_expands_core_owned_window;
    case "graph import forwards payload to storage"
      graph_import_forwards_payload_to_storage;
    case "opening graph reads authoritative projections once"
      opening_graph_reads_authoritative_projections_once;
    case "graph storage errors preserve codes and payload priority"
      graph_storage_errors_preserve_codes_and_payload_priority;
    case "graph storage success can fail projection validation"
      graph_storage_success_can_fail_projection_validation;
    case "websocket lifecycle applies events exactly once"
      websocket_lifecycle_applies_events_exactly_once;
    case "websocket self echo clears local pending capture"
      websocket_self_echo_clears_local_pending_capture;
    case "authoritative assets retain cached local file path"
      authoritative_assets_retain_cached_local_file_path;
    case "task status updates preserve custom icon color"
      task_status_updates_preserve_custom_icon_color;
    case "authoritative sync preserves editor and updates visible remote block"
      authoritative_sync_preserves_editor_and_updates_visible_remote_block;
    case "journal pagination preserves editor selection and zoom"
      journal_pagination_preserves_editor_selection_and_zoom;
    case "outliner editing and autocomplete remain owned by core"
      outliner_editing_and_autocomplete_remain_owned_by_core;
    case "tag autocomplete candidates use canonical graph identity"
      tag_autocomplete_candidates_use_canonical_graph_identity;
    case "block reference completion saves the selected UUID" block_reference_completion_saves_the_selected_uuid;
    case "page autocomplete searches beyond sidebar and current page"
      page_autocomplete_searches_beyond_sidebar_and_current_page;
    case "websocket errors distinguish snapshot recovery from apply failures"
      websocket_errors_distinguish_snapshot_recovery_from_apply_failures;
    case "pending sync rejects stale completions and preserves failed block"
      pending_sync_rejects_stale_completions_and_preserves_failed_block;
    case "pending sync completions after cancellation are idempotent"
      pending_sync_completions_after_cancellation_are_idempotent;
    case "pending sync duplicate completions are idempotent"
      pending_sync_duplicate_completions_are_idempotent;
    case "task update pump submits title before status"
      task_update_pump_submits_title_before_status;
    case "encrypted graph creation provisions uploads and cleans up in order"
      encrypted_graph_creation_provisions_uploads_and_cleans_up_in_order;
    case "journal calendar opens existing days and creates missing days"
      journal_calendar_opens_existing_days_and_creates_missing_days;
    case "semantic capture pump never calls blocking transport"
      semantic_capture_pump_never_calls_blocking_transport;
    case "encrypted task stages journal before status and drains both requests"
      encrypted_task_stages_journal_before_status_and_drains_both_requests;
    case "graph creation stops after initial upload failure"
      graph_creation_stops_after_initial_upload_failure;
    case "autosave emits bounded patches and advances expected title"
      autosave_emits_bounded_patches_and_advances_expected_title;
    case "confirmed delete stages one operation and removes only selected row"
      confirmed_delete_stages_one_operation_and_removes_only_selected_row;
    case "task status stages canonical property reference"
      task_status_stages_canonical_property_reference;
    case "collapse and zoom replace only affected row ranges"
      collapse_and_zoom_replace_only_affected_row_ranges;
    case "projected title updates stage semantic transactions"
      projected_title_updates_stage_semantic_transactions;
    case "startup restores durable operations without restaging each edit"
      startup_restores_durable_operations_without_restaging_each_edit;
    case "stale queue head waits for reconciliation before advancing"
      stale_queue_head_waits_for_reconciliation_before_advancing;
    case "pending sync response is bounded independently of page size"
      pending_sync_response_is_bounded_independently_of_page_size;
    case "semantic completion persists accepted server cursor"
      semantic_completion_persists_accepted_server_cursor;
    case "HTTP acceptance waits for confirmed journal cursor"
      http_acceptance_waits_for_the_confirmed_journal_cursor;
    case "captures after acceptance still stage against authoritative cursor"
      captures_after_acceptance_still_stage_against_authoritative_cursor;
    case "rejected and offline transactions remain retryable with stable identity"
      rejected_and_offline_transactions_remain_retryable_with_stable_identity;
    case "delete block stages a cursor guarded semantic request"
      delete_block_stages_a_cursor_guarded_semantic_request;
    case "split block stages one atomic semantic intent"
      split_block_stages_one_atomic_semantic_intent;
    case "confirmed journal releases next durable operation"
      confirmed_journal_releases_next_durable_operation;
    case "merge backward stages one atomic semantic intent"
      merge_backward_stages_one_atomic_semantic_intent;
    case "move blocks stages one ordered batch"
      move_blocks_stages_one_ordered_batch;
    case "delete blocks stages one deduplicated batch"
      delete_blocks_stages_one_deduplicated_batch;
    case "status update stages a typed property intent"
      status_update_stages_a_typed_property_intent;
    case "delete without authoritative cursor does not stage"
      delete_without_authoritative_cursor_does_not_stage;
    case "offline title edits remain visible over authoritative blocks"
      offline_title_edits_remain_visible_over_authoritative_blocks;
    case "consecutive structural edits stay local and submit in dependency order"
      consecutive_structural_edits_stay_local_and_submit_in_dependency_order;
    case "page scoped deletes preserve optimistic blocks with a lagging reader"
      page_scoped_deletes_preserve_optimistic_blocks_with_a_lagging_reader;
    case "node route insertion preserves order with a lagging reader"
      node_route_insertion_preserves_order_with_a_lagging_reader;
    case "structural patches preserve empty boundaries prefixes and suffixes"
      structural_patches_preserve_empty_boundaries_prefixes_and_suffixes;
    case "editing status uses live properties instead of stale overlay"
      editing_status_uses_live_properties_instead_of_stale_overlay;
    case "split block does not inherit task or asset metadata"
      split_block_does_not_inherit_task_or_asset_metadata;
    case "journal split reads one page and inserts the first child"
      journal_split_reads_one_page_and_inserts_the_first_child;
    case "graph switching keeps optimistic models isolated"
      graph_switching_keeps_optimistic_models_isolated;
    case "collapse finishes editor and saves title exactly once"
      collapse_finishes_editor_and_saves_title_exactly_once;
    case "hide keyboard saves before publishing editor dismissal"
      hide_keyboard_saves_before_publishing_editor_dismissal;
    case "autocomplete creates page without saving block draft"
      autocomplete_creates_page_without_saving_block_draft;
    case "saved title immediately renders new reference metadata"
      saved_title_immediately_renders_new_reference_metadata;
    case "tag completion immediately publishes tag metadata"
      tag_completion_immediately_publishes_tag_metadata;
    case "asset acknowledgements preserve applied cursor across replay timings"
      asset_acknowledgements_preserve_applied_cursor_across_replay_timings;
    case "late http acknowledgement cannot rewind transport cursor"
      late_http_acknowledgement_cannot_rewind_transport_cursor;
    case "targeted assets appear immediately in selected page projection"
      targeted_assets_appear_immediately_in_selected_page_projection;
    case "task and asset capture return optimistic blocks"
      task_and_asset_capture_return_optimistic_blocks;
    case "targeted assets retain parent and page from cached block"
      targeted_assets_retain_parent_and_page_from_cached_block;
    case "targeted asset upload uses stable block uuid"
      targeted_asset_upload_uses_stable_block_uuid;
    case "shared images insert bounded row patches and normalize upload type"
      shared_images_insert_bounded_row_patches_and_normalize_upload_type;
    case "clearing authentication invalidates old sync transport" clearing_authentication_invalidates_old_sync_transport;
    case "clearing authentication cancels requests without dropping local edits" clearing_authentication_cancels_requests_without_dropping_local_edits;
    case "pending assets wait for authentication and resume after configuration"
      pending_assets_wait_for_authentication_and_resume_after_configuration;
    case "asset payload errors do not create local blocks"
      asset_payload_errors_do_not_create_local_blocks;
    case "asset staging errors preserve cached file and error category"
      asset_staging_errors_preserve_cached_file_and_error_category;
    case "asset workflow captures view before caching and loads stage afterward"
      asset_workflow_captures_view_before_caching_and_loads_stage_afterward;
    case "local insertions share projection with journals nodes and editor"
      local_insertions_share_projection_with_journals_nodes_and_editor;
    case "graph projection does not leak legacy cache blocks"
      graph_projection_does_not_leak_legacy_cache_blocks;
    case "child insertion validates fields before loading cursor"
      child_insertion_validates_fields_before_loading_cursor;
    case "child insertion without graph writes through local parent"
      child_insertion_without_graph_writes_through_local_parent;
    case "child insertion preserves cursor parent and staging errors"
      child_insertion_preserves_cursor_parent_and_staging_errors;
    case "child operation orders only within the parent page"
      child_operation_orders_only_within_the_parent_page;
    case "plain assets project before upload and queue stable datom transactions"
      plain_assets_project_before_upload_and_queue_stable_datom_transactions;
    case "failed raw uploads retry without queuing datoms"
      failed_raw_uploads_retry_without_queuing_datoms;
    case "encrypted capture stages persistent insert and uses datom endpoint"
      encrypted_capture_stages_persistent_insert_and_uses_datom_endpoint;
    case "page favorite updates sidebar and preserves operation fields"
      page_favorite_updates_sidebar_and_preserves_operation_fields;
    case "page deletion updates sidebar and preserves operation fields"
      page_deletion_updates_sidebar_and_preserves_operation_fields;
    case "flashcard review removes due card and preserves operation fields"
      flashcard_review_removes_due_card_and_preserves_operation_fields;
    case "page and review actions validate before calling services"
      page_and_review_actions_validate_before_calling_services;
    case "page and review actions preserve service errors"
      page_and_review_actions_preserve_service_errors;
    case "page and review actions preserve precondition priority"
      page_and_review_actions_preserve_precondition_priority;
    case "page service exceptions are not reclassified as payload json errors"
      page_service_exceptions_are_not_reclassified_as_payload_json_errors;
    case "refresh reads local graph without HTTP" refresh_reads_local_graph_without_http;
    case "optimistic capture is returned before sync"
      optimistic_capture_is_returned_before_sync;
    case "title normalization preserves operation and stages tags first"
      title_normalization_preserves_operation_and_stages_tags_first;
    case "title normalization keeps original intent on wrong arity"
      title_normalization_keeps_original_intent_on_wrong_arity;
    case "title normalization skips unrelated intents and absent service"
      title_normalization_skips_unrelated_intents_and_absent_service;
    case "capture requires projection cursor before looking up journal"
      capture_requires_projection_cursor_before_looking_up_journal;
    case "asset operation rejects missing cursor before loading destination"
      asset_operation_rejects_missing_cursor_before_loading_destination;
    case "asset operation rejects incomplete metadata before loading destination"
      asset_operation_rejects_incomplete_metadata_before_loading_destination;
    case "asset operation does not fallback from missing parent to journal"
      asset_operation_does_not_fallback_from_missing_parent_to_journal;
    case "asset operation uses journal date and preserves durable metadata"
      asset_operation_uses_journal_date_and_preserves_durable_metadata;
    case "asset operation orders after siblings without counting itself"
      asset_operation_orders_after_siblings_without_counting_itself;
    case "encrypted asset upload stages datoms and cleans temporary payload"
      encrypted_asset_upload_stages_datoms_and_cleans_temporary_payload;
    case "graph creation validates before performing io"
      graph_creation_validates_before_performing_io;
    case "graph creation preserves transport and response errors"
      graph_creation_preserves_transport_and_response_errors;
    case "encrypted graph creation stops when key provisioning is unavailable"
      encrypted_graph_creation_stops_when_key_provisioning_is_unavailable;
    case "encrypted graph creation stops after key provisioning failure"
      encrypted_graph_creation_stops_after_key_provisioning_failure;
    case "graph creation cleans up after upload http failure"
      graph_creation_cleans_up_after_upload_http_failure;
    case "encrypted graph selection attempts offline key cache"
      encrypted_graph_selection_attempts_offline_key_cache;
    case "encrypted graph unlock forwards password and updates state"
      encrypted_graph_unlock_forwards_password_and_updates_state;
    case "session rejects legacy sync action" session_rejects_legacy_sync_action;
    case "session without graph has no due flashcards"
      session_without_graph_has_no_due_flashcards;
    case "session restores cached graph name without token"
      session_restores_cached_graph_name_without_token;
    case "session clear related exposes related blocks"
      session_clear_related_exposes_related_blocks;
    case "rpc routing validates before executing actions"
      rpc_routing_validates_before_executing_actions;
    case "rpc routing keeps first fields and catches handler errors"
      rpc_routing_keeps_first_fields_and_catches_handler_errors;
    case "capture payload supports plain text and validated json"
      capture_payload_supports_plain_text_and_validated_json;
    case "rpc response envelopes preserve version and error contract"
      rpc_response_envelopes_preserve_version_and_error_contract;
    case "pending request preserves body and upload wire fields"
      pending_request_preserves_body_and_upload_wire_fields;
    case "toolbar wire actions preserve all public mappings"
      toolbar_wire_actions_preserve_all_public_mappings;
    case "flashcard wire ratings preserve values and validation"
      flashcard_wire_ratings_preserve_values_and_validation;
    case "outliner events decode navigation and editing payloads"
      outliner_events_decode_navigation_and_editing_payloads;
    case "outliner event errors preserve wire validation"
      outliner_event_errors_preserve_wire_validation;
    case "outliner drop and status events preserve priority"
      outliner_drop_and_status_events_preserve_priority;
    case "optimistic intents preserve unmodified block fields"
      optimistic_intents_preserve_unmodified_block_fields;
    case "optimistic assets replace in place and preserve local path"
      optimistic_assets_replace_in_place_and_preserve_local_path;
    case "optimistic splits preserve source location and ignore missing source"
      optimistic_splits_preserve_source_location_and_ignore_missing_source;
    case "optimistic merges use explicit title or concatenate without separator"
      optimistic_merges_use_explicit_title_or_concatenate_without_separator;
    case "optimistic moves apply in order and deletes only remove specified ids"
      optimistic_moves_apply_in_order_and_deletes_only_remove_specified_ids;
    case "optimistic status projection handles builtins custom refs and clearing"
      optimistic_status_projection_handles_builtins_custom_refs_and_clearing;
    case "optimistic overlay preserves draft fields and refreshes live metadata"
      optimistic_overlay_preserves_draft_fields_and_refreshes_live_metadata;
    case "optimistic overlay only applies while editing and keeps cached membership"
      optimistic_overlay_only_applies_while_editing_and_keeps_cached_membership;
    case "outliner rows preserve hierarchy video targets and serializer"
      outliner_rows_preserve_hierarchy_video_targets_and_serializer;
    case "outliner candidate json preserves filtering and no request"
      outliner_candidate_json_preserves_filtering_and_no_request;
    case "graph json keeps null schema and readiness flags"
      graph_json_keeps_null_schema_and_readiness_flags;
    case "search json keeps page and breadcrumb order"
      search_json_keeps_page_and_breadcrumb_order;
    case "flashcard json keeps counters state and children"
      flashcard_json_keeps_counters_state_and_children;
    case "block json publishes resolved markup and omits absent fields"
      block_json_publishes_resolved_markup_and_omits_absent_fields;
    case "block json preserves asset and journal fields"
      block_json_preserves_asset_and_journal_fields;
    case "status json requires both icon type and id"
      status_json_requires_both_icon_type_and_id;
    case "empty outliner state keeps null and empty wire fields"
      empty_outliner_state_keeps_null_and_empty_wire_fields;
    case "outliner state serializes drafts and orders identifiers"
      outliner_state_serializes_drafts_and_orders_identifiers;
    case "platform commands preserve their json wire format"
      platform_commands_preserve_their_json_wire_format;
    case "youtube timestamps follow the most recent video across blocks"
      youtube_timestamps_follow_the_most_recent_video_across_blocks;
    case "youtube targets ignore other videos and preserve original url"
      youtube_targets_ignore_other_videos_and_preserve_original_url;
  ]
