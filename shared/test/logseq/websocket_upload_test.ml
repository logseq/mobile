open Test_util
open Rpc_test

let upload_session () =
  let staged = ref [] in
  let session = staging_session 42 (ref [synced_block "remote" "Old"]) staged in
  ignore (response_result (dispatch_json session "updateBlock"
    {|{"uuid":"remote","operationId":"op-ws","expectedTitle":"Old","title":"Pending","status":null}|}));
  let generation = sync_generation (begin_sync_transport session) in
  ignore (sync_event session generation "opened" []);
  session, generation, staged

let uploads_use_the_graph_websocket () =
  let session, _, _ = upload_session () in
  let request = required_pending_request session in
  check_eq ~msg:"graph transactions must never enter the HTTP transport"
    (member "method" request) (`String "WS");
  check_eq (member "url" request) (`String "ws://127.0.0.1:8787/sync/plain-1");
  let body = member "bodyObject" request in
  check_eq (member "type" body) (`String "tx/batch");
  check_eq (member "t-before" body) (`Int 42);
  check_eq (member "tx-id" (List.hd (json_items "txs" body))) (`String "op-ws")

let responses_are_routed_to_the_current_upload () =
  List.iter (fun body ->
    let session, generation, _ = upload_session () in
    let request = required_pending_request session in
    let result = sync_event session generation "frame" ["body", `String body] in
    check_eq (sync_command_kinds result) ["pending-result"];
    let command = List.hd (sync_commands result) in
    check_eq (member "id" command) (member "id" request);
    check_eq (member "body" command) (`String body))
    [ {|{"type":"tx/batch/ok","t-before":42,"t":43,"txs":[]}|};
      {|{"type":"tx/reject","reason":"stale","t":43}|};
      {|{"type":"tx/reject","reason":"invalid tx"}|} ]

let stale_connections_and_duplicate_acks_cannot_complete_an_upload () =
  let session, generation, _ = upload_session () in
  ignore (required_pending_request session);
  let ack = {|{"type":"tx/batch/ok","t-before":41,"t":42,"txs":[]}|} in
  check_eq (sync_commands (sync_event session generation "frame" ["body", `String ack])) [];
  let next = sync_generation (begin_sync_transport session) in
  ignore (sync_event session next "opened" []);
  let ack = {|{"type":"tx/batch/ok","t-before":42,"t":43,"txs":[]}|} in
  check_eq (sync_commands (sync_event session generation "frame" ["body", `String ack])) [];
  check_eq (sync_command_kinds (sync_event session next "frame" ["body", `String ack])) ["pending-result"]

let retries_keep_the_transaction_identity () =
  let session, _, _ = upload_session () in
  let request = required_pending_request session in
  let failed = response_result (dispatch_json session "completePendingSync"
    (Json.to_string (`Assoc ["id", member "id" request; "error", `String "socket closed"]))) in
  let retry = member "pendingSyncRequest" failed in
  check_eq (member "method" retry) (`String "WS");
  check_eq (member "body" retry) (member "body" request);
  check_eq (member "id" retry) (member "id" request);
  check_eq (member "delayMs" retry) (`Int 1000)

let cases =
  [ case "uploads use the graph websocket" uploads_use_the_graph_websocket;
    case "responses route to the current upload" responses_are_routed_to_the_current_upload;
    case "stale connections and duplicate ACKs are ignored" stale_connections_and_duplicate_acks_cannot_complete_an_upload;
    case "disconnect retries preserve the transaction" retries_keep_the_transaction_identity ]
