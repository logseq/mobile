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
    check_eq (U.member "deepLinkQuickAction" response) (`String host)) ["capture"; "audio"; "journal"];
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

let cases = [
  case "graph deep links resolve graph page and block targets without changing the wrong graph" graph_deep_links_resolve_graphs_pages_and_blocks;
  case "late recording transcripts are core owned and idempotent" late_recording_transcripts_are_core_owned_and_idempotent;
  case "shared text is canonical and retries are idempotent" shared_text_is_canonical_and_retries_are_idempotent;
  case "empty or invalid shared payload does not create a note" empty_or_invalid_shared_payload_does_not_create_a_note;
  case "deep links share capture and quick action semantics" deep_links_share_capture_and_quick_action_semantics;
]
