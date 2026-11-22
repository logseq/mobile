open Test_util
module J = Yojson.Basic
module U = Yojson.Basic.Util
let call session action fields = Rpc_test.dispatch_json session action (J.to_string (`Assoc fields))
let session () = Rpc_session.create_session Rpc_session.default_options
let captured session uuid = Cache_model.read_block (Rpc_session.state session).model uuid

let shared_text_is_canonical_and_retries_are_idempotent () =
  List.iter (fun (fields, expected) ->
    let session = session () in
    let response = call session "captureShared" (("uuid", `String "share-id") :: fields) in
    ignore (Rpc_test.response_result response);
    let first = Option.get (captured session "share-id") in
    check_eq first.title expected;
    ignore (Rpc_test.response_result (call session "captureShared" [
      "uuid", `String "share-id"; "text", `String "A retry must not replace the note"]));
    check_eq (captured session "share-id") (Some first)) [
    ["text", `String "  选中文本 C++  "], "选中文本 C++";
    ["text", `String "An Example excerpt"; "title", `String "Example"], "An Example excerpt";
    ["text", `String "Excerpt"; "title", `String "Example"], "Excerpt\nExample";
    ["text", `String "https://example.com/article"; "title", `String "Example"], "[Example](https://example.com/article)";
    ["url", `String "https://example.com"; "title", `String "https://example.com"], "https://example.com";
    ["text", `String "Excerpt"; "url", `String "https://example.com"; "title", `String "Example"], "Excerpt\n[Example](https://example.com)";
    ["title", `String "Only a title"], "Only a title";
  ]

let empty_or_invalid_shared_payload_does_not_create_a_note () =
  let session = session () in
  List.iter (fun fields ->
    let response = call session "captureShared" fields in
    check_eq (U.member "ok" response) (`Bool false);
    check_eq (Cache_model.all_blocks (Rpc_session.state session).model) []) [
    ["uuid", `String "share-id"; "text", `String " \n "];
    ["text", `String "Missing identity"];
    ["uuid", `String "share-id"; "text", `Int 3]]

let deep_links_share_capture_and_quick_action_semantics () =
  let session = session () in
  let fields host query = ["uuid", `String "deep-link-id"; "scheme", `String "LOGSEQ";
    "host", `String host; "query", `List (List.map (fun (name, value) ->
      `Assoc ["name", `String name; "value", `String value]) query)] in
  let captured_response = call session "handleDeepLink" (fields "CAPTURE" ["text", "old"; "text", ""; "text", "C++ 中文"]) in
  ignore (Rpc_test.response_result captured_response);
  check_eq (Option.map (fun (b : Cache_model.block) -> b.title) (captured session "deep-link-id")) (Some "C++ 中文");
  List.iter (fun host ->
    let response = call session "handleDeepLink" (fields host []) |> Rpc_test.response_result in
    check_eq (U.member "deepLinkQuickAction" response) (`String host)) ["capture"; "audio"; "journal"; "task"];
  let ignored = call session "handleDeepLink" (fields "unknown" []) |> Rpc_test.response_result in
  check_eq (U.member "deepLinkQuickAction" ignored) `Null

let late_recording_transcripts_are_core_owned_and_idempotent () =
  let session = session () in
  ignore (Rpc_test.response_result (Rpc_test.dispatch_json session "addAsset"
    {|{"uuid":"recording","title":"recording.m4a","assetType":"m4a","assetSize":12,"assetChecksum":"abc","localPath":"Assets/recording.m4a"}|}));
  List.iter (fun _ -> ignore (Rpc_test.response_result (Core_effect_test.execute session "recording-transcribed"
    ["uuid", `String "recording"; "text", `String "Spoken note"]))) [1; 2];
  let children = Cache_model.all_blocks (Rpc_session.state session).model
    |> List.filter (fun (b : Cache_model.block) -> b.parent_id = Some "recording") in
  check_eq (List.length children) 1;
  check_eq (List.hd children).title "Spoken note"

let graph_deep_links_resolve_graphs_pages_and_blocks () =
  let db = Query_block_test.fixture "#Project" in
  let catalog = {|{"graphs":[{"graph-id":"plain-1","graph-name":"Plain","graph-e2ee?":false,"graph-ready-for-use?":true},{"graph-id":"other","graph-name":"Other 中文 +","graph-e2ee?":false,"graph-ready-for-use?":true}]}|} in
  let session = Rpc_session.create_session {Rpc_session.default_options with
    load_graph_catalog = Some (fun () -> Some catalog); graph_db = Some (fun () -> Some db)} in
  ignore (Rpc_test.configure_plain_session session);
  let fields path query = ["scheme", `String "logseq"; "host", `String "graph"; "path", `String path;
    "query", `List (List.map (fun (name, value) -> `Assoc ["name", `String name; "value", `String value]) query)] in
  let navigate path query = call session "handleDeepLink" (fields path query) in
  let result path query = let response = navigate path query in
    check_eq ~msg:(J.to_string response) (U.member "ok" response) (`Bool true); Rpc_test.response_result response in
  check_eq (U.member "deepLinkQuickAction" (result "/Plain" [])) (`String "journal");
  check_eq (U.member "deepLinkNodeUuid" (result "/Plain" ["page", "Workspace"])) (`String Query_block_test.page);
  check_eq (U.member "deepLinkNodeUuid" (result "/plain-1" ["block-id", Query_block_test.alpha])) (`String Query_block_test.alpha);
  check_eq ~msg:"a block-only URL resolves in the selected graph"
    (U.member "deepLinkNodeUuid" (result "/" ["block-id", Query_block_test.alpha])) (`String Query_block_test.alpha);
  check_eq ~msg:"an explicit graph ID query takes precedence over the path name"
    (U.member "deepLinkGraphId" (result "/Plain" ["graph-id", "other"; "block-id", Query_block_test.alpha])) (`String "other");
  check_eq (U.member "deepLinkNodeUuid" (result "/Plain" ["page", "Workspace"; "block-id", Query_block_test.beta])) (`String Query_block_test.beta);
  let other = result "/Other 中文 +" ["page", "Workspace"] in
  check_eq ~msg:"a graph switch must finish before resolving nodes in that graph"
    (U.member "deepLinkGraphId" other) (`String "other");
  check_eq (U.member "deepLinkNodeUuid" other) `Null;
  check_eq (Option.map (fun (config : Api.api_config) -> config.graph_id) (Rpc_session.state session).config) (Some "plain-1");
  List.iter (fun (path, query) -> check_eq (U.member "ok" (navigate path query)) (`Bool false))
    ["/Missing graph", []; "/", []; "/Plain", ["page", "Missing page"]; "/Plain", ["block-id", "missing"]];
  ignore (Rpc_test.dispatch_json session "configure" {|{"baseUrl":"http://127.0.0.1:8787","graphId":"other","token":"access"}|});
  check_eq (U.member "deepLinkNodeUuid" (result "/Other 中文 +" ["page", "Workspace"])) (`String Query_block_test.page)

let widget_block_link session uuid =
  let query = ["graph-id", "plain-1"; "block-id", uuid; "widget-action", "open-block"] in
  call session "handleDeepLink" ["scheme", `String "logseq"; "host", `String "graph";
    "query", `List (List.map (fun (name, value) -> `Assoc ["name", `String name; "value", `String value]) query)]

let widget_block_links_open_in_the_initial_projection () =
  let open Query_block_test in
  let db = fixture "A test block" in
  let session = Rpc_session.create_session { Rpc_session.default_options with
    load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
    graph_db = Some (fun () -> Some db);
    graph_page_blocks = Some (fun uuid -> Some (Graph_read.blocks_for_page (fun s -> Ok s) db uuid));
    graph_node_destination = Some (Graph_read.node_destination (fun s -> Ok s) db) } in
  ignore (Rpc_test.configure_plain_session session);
  let open_widget = widget_block_link session in
  let launch uuid =
    let response = open_widget uuid in
    let result = Rpc_test.response_result response in
    check_eq (U.member "widgetBlockUuid" result) (`String uuid);
    check_eq (items "nodeRoutes" result |> List.map (U.member "uuid")) [`String uuid];
    match Response_snapshot.decode_json_response response with
    | Ok snapshot -> Model.ApplyCoreSnapshot snapshot
    | Error message -> fail message in
  let launched = Model.update (Model.initial ()) (launch alpha) in
  check_eq (Model.app_node_routes launched |> List.map (fun route -> route.Model.node_uuid)) [alpha];
  let composing = Model.update launched Model.ExpandComposer in
  check composing.composer_expanded;
  check composing.composer_autofocus;
  let repeated = Model.update composing (launch alpha) in
  check repeated.composer_expanded;
  let switched = Model.update repeated (launch beta) in
  check_eq (Model.app_node_routes switched |> List.map (fun route -> route.Model.node_uuid)) [beta];
  check_eq (U.member "ok" (open_widget "missing")) (`Bool false)

let widget_block_links_commit_the_outgoing_detail_draft () =
  let open Query_block_test in
  let db = ref (fixture "A test block") in
  let fail_save = ref true in
  let saves = ref 0 in
  let draft = "See [[Roadmap" in
  let session = Rpc_test.configure_plain_session
    (Rpc_session.create_session { Rpc_session.default_options with
      load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
      sync_cursor = Some (fun () -> Some 92);
      graph_db = Some (fun () -> Some !db);
      graph_page_blocks = Some (fun uuid -> Some (Graph_read.blocks_for_page (fun s -> Ok s) !db uuid));
      graph_node_destination = Some (fun uuid -> Graph_read.node_destination (fun s -> Ok s) !db uuid);
      prepare_operation = Some Rpc_test.prepare_operation;
      stage_operation = Some (fun operation ->
        incr saves;
        match operation.Pending_ops.intent with
        | Pending_ops.Save_title saved ->
          check_eq saved.uuid alpha;
          check_eq saved.title draft;
          if !fail_save then Error "Local save failed"
          else begin
            db := Datascript.db_with [put alpha "block/title" (Datascript.String saved.title)] !db;
            Ok ()
          end
        | _ -> fail "Expected a title save") }) in
  let current_routes () =
    List.map (fun (route : Session_types.node_route) -> route.uuid)
      (Rpc_session.state session).node_routes in
  ignore (Rpc_test.response_result (widget_block_link session alpha));
  ignore (Rpc_test.outliner_block_event session "tapBlock" alpha);
  ignore (call session "outlinerEvent" ["type", `String "textChanged"; "title", `String draft;
    "caretUTF16Offset", `Int (String.length draft)] |> Rpc_test.response_result);
  check (Outliner_state.autocomplete (Rpc_session.state session).outliner_state <> None);
  let failed = widget_block_link session beta in
  check_eq (Rpc_test.response_error_code failed) "outliner_effect_failed";
  check_eq (U.member "message" (U.member "error" failed)) (`String "Local save failed");
  check_eq (current_routes ()) [alpha];
  check_eq (Outliner_state.editing_title (Rpc_session.state session).outliner_state) (Some draft);
  fail_save := false;
  let switched = widget_block_link session beta |> Rpc_test.response_result in
  check_eq (U.member "widgetBlockUuid" switched) (`String beta);
  check_eq (current_routes ()) [beta];
  check_eq !saves 2;
  let saved = Datascript.entid !db "block/uuid" (Datascript.Uuid alpha)
    |> Option.get in
  check_eq (Graph_read.value !db saved "block/title") (Some (Datascript.String draft))

let widgets_project_visible_blocks_and_update_a_task_in_the_correct_graph () =
  let module Ds = Datascript in
  let open Query_block_test in
  let asset = "10000000-0000-4000-8000-000000000021" in
  let db = ref (Ds.db_with [
    put alpha "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Task"));
    Ds.Add (Ds.Entity_id 900021, "block/uuid", Ds.Uuid asset);
    put asset "block/page" (Ds.Ref_to (ref_uuid page));
    put asset "block/title" (Ds.String "A photo attachment");
    put asset "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Asset"));
    put beta "block/title" (Ds.String "四字测试");
    put definition "block/title" (Ds.String "五个字符啊");
    put owner "logseq.property/hide?" (Ds.Bool true);
  ] (fixture "Original query")) in
  let staged = ref [] in
  let private_unlocked = ref false in
  let private_graph = {|{"graph-id":"private","graph-name":"Private","graph-e2ee?":true,"graph-ready-for-use?":true}|} in
  let catalog = {|{"graphs":[{"graph-id":"plain-1","graph-name":"Plain","graph-e2ee?":false,"graph-ready-for-use?":true},
    {"graph-id":"other","graph-name":"Other","graph-e2ee?":false,"graph-ready-for-use?":true},|}
    ^ private_graph ^ "]}" in
  let session = Rpc_session.create_session { Rpc_session.default_options with
    load_graph_catalog = Some (fun () -> Some catalog);
    graph_db = Some (fun () -> Some !db);
    open_graph = Some (fun _ -> Ok ());
    model_for_graph = Some (fun _ -> Cache_model.create None);
    graph_unlocked = Some (fun graph -> graph = "private" && !private_unlocked);
    sync_cursor = Some (fun () -> Some 92);
    stage_operation = Some (fun operation ->
      Result.map (fun tx ->
        db := Ds.db_with tx !db;
        staged := operation :: !staged) (Pending_projection.compile !db operation.Pending_ops.intent));
    prepare_operation = Some Rpc_test.prepare_operation;
  } in
  ignore (Rpc_test.configure_plain_session session);
  ignore (call session "openGraph" ["graphId", `String "plain-1"] |> Rpc_test.response_result);
  let snapshot () = call session "widgetSnapshot" [] |> Rpc_test.response_result in
  let ids key content = items key content |> List.map (U.member "uuid") |> List.sort compare in
  check_eq (ids "tasks" (snapshot ())) [`String alpha];
  check_eq (ids "randomBlocks" (snapshot ())) [`String definition; `String alpha];
  let refreshed = call session "widgetSnapshot" ["resampleRandomBlocks", `Bool true]
    |> Rpc_test.response_result in
  check_eq (ids "randomBlocks" refreshed) [`String definition; `String alpha];
  let original = List.hd (items "tasks" (snapshot ())) in
  let choose task ident =
    items "statusChoices" task |> List.find (fun choice -> U.member "ident" choice = `String ident) in
  let expected = U.member "statusUuid" original in
  let choice = choose original "logseq.property/status.done" in
  let appearance = U.member "appearance" choice in
  check_eq (U.member "icon" appearance) (`String "app:task-done");
  let next = U.member "uuid" choice in
  let set_status graph expected status = call session "setWidgetTaskStatus" [
    "graphId", `String graph; "uuid", `String alpha; "expectedStatusUuid", expected; "statusUuid", status] in
  let change graph = set_status graph expected next in
  check_eq (U.member "ok" (change "private")) (`Bool false);
  check_eq !staged [];
  ignore (change "plain-1" |> Rpc_test.response_result);
  check_eq (List.length !staged) 1;
  let task = List.hd (items "tasks" (snapshot ())) in
  check_eq (U.member "status" task) (U.member "title" choice);
  check_eq (U.member "statusUuid" task) next;
  check_eq (U.member "statusAppearance" task) appearance;
  ignore (change "plain-1" |> Rpc_test.response_result);
  check_eq (U.member "ok" (set_status "plain-1" expected expected)) (`Bool false);
  check_eq (List.length !staged) 1;
  let select graph = ignore (call session "configure" [
    "baseUrl", `String "http://127.0.0.1:8787"; "graphId", `String graph; "token", `String "access"]) in
  select "other";
  check_eq (ids "tasks" (snapshot ())) [];
  check_eq (ids "randomBlocks" (snapshot ())) [];
  select "private";
  ignore (call session "openGraph" ["graphId", `String "private"] |> Rpc_test.response_result);
  check_eq (U.member "graphLocked" (snapshot ())) (`Bool true);
  check_eq (ids "tasks" (snapshot ())) [];
  check_eq (ids "randomBlocks" (snapshot ())) [];
  private_unlocked := true;
  check_eq (ids "tasks" (snapshot ())) [`String alpha];
  check_eq (ids "randomBlocks" (snapshot ())) [`String definition; `String alpha];
  ignore (set_status "private" next expected |> Rpc_test.response_result);
  check_eq (List.length !staged) 2;
  private_unlocked := false;
  check_eq (ids "tasks" (snapshot ())) []

let widgets_project_the_ten_highest_priority_tasks () =
  let module Ds = Datascript in
  let open Query_block_test in
  let tasks = List.init 20 (fun index ->
    let title = Printf.sprintf "Task %02d" index in
    let uuid = Printf.sprintf "10000000-0000-4000-8000-%012d" (100 + index) in
    [Ds.Add (Ds.Entity_id (900100 + index), "block/uuid", Ds.Uuid uuid);
     put uuid "block/page" (Ds.Ref_to (ref_uuid page));
     put uuid "block/title" (Ds.String title);
     put uuid "block/updated-at" (Ds.Int64 (Int64.of_int index));
     put uuid "block/tags" (Ds.Ref_to (Ds.Ident "logseq.class/Task"))]) in
  let db = Ds.db_with (List.concat tasks) (fixture "A small text block") in
  let session = Rpc_session.create_session { Rpc_session.default_options with
    graph_db = Some (fun () -> Some db) } in
  ignore (Rpc_test.configure_plain_session session);
  let snapshot = call session "widgetSnapshot" [] |> Rpc_test.response_result in
  let titles = items "tasks" snapshot |> List.map (U.member "title") in
  check_eq titles (List.init 10 (fun index -> `String (Printf.sprintf "Task %02d" (19 - index))))

let cases = [
  case "widget links publish a ready block route and its composer" widget_block_links_open_in_the_initial_projection;
  case "widget links commit the outgoing detail draft" widget_block_links_commit_the_outgoing_detail_draft;
  case "widgets project the ten highest priority tasks" widgets_project_the_ten_highest_priority_tasks;
  case "widgets show eligible blocks and stage status only in the task graph"
    widgets_project_visible_blocks_and_update_a_task_in_the_correct_graph;
  case "graph deep links resolve graph page and block targets without changing the wrong graph" graph_deep_links_resolve_graphs_pages_and_blocks;
  case "late recording transcripts are core owned and idempotent" late_recording_transcripts_are_core_owned_and_idempotent;
  case "shared text is canonical and retries are idempotent" shared_text_is_canonical_and_retries_are_idempotent;
  case "empty or invalid shared payload does not create a note" empty_or_invalid_shared_payload_does_not_create_a_note;
  case "deep links share capture and quick action semantics" deep_links_share_capture_and_quick_action_semantics;
]
