open Test_util
open Rpc_test

module Runtime = Graph_runtime
module Fixture = Graph_runtime_test

let require = function Ok value -> value | Error message -> fail message
let uuid n = Printf.sprintf "00000000-0000-4000-8000-%012d" n

let with_session f =
  Fixture.with_runtime (fun path conn runtime ->
    ignore (Datascript.reset_conn conn (Datascript.db_with
      [Fixture.add 1 "block/uuid" (Datascript.Uuid (uuid 100));
       Fixture.add 10 "block/uuid" (Datascript.Uuid (uuid 101))]
      (Datascript.conn_db conn)));
    Runtime.rebase runtime 42 [] [];
    let host = Mobile_session.create (fun _ -> fail "unexpected crypto call") in
    let graph = host.Mobile_session.database.Mobile_database.graph in
    let checkpoint = path ^ ".checkpoint" in
    graph.current := Some { Mobile_graph.conn; read_runtime = runtime;
      state = Sync_session.create_state "plain-1" "1" 42; checkpoint_path = checkpoint;
      graph_id = "plain-1"; e2ee = false };
    let options = Mobile_session.host_options host.database host.keyring None in
    let session = configure_plain_session (Session.create_session { options with
      load_graph_catalog = Some (fun () -> Some plain_graph_catalog) }) in
    Fun.protect ~finally:(fun () -> Fixture.cleanup_store path;
      Fixture.remove_if_exists checkpoint) (fun () -> f session graph runtime path conn))

let stage session id intent =
  let base_t = Option.get (Session.projection_server_t session) in
  require (Session.enqueue_semantic session { Ops.operation_id = id; base_t; state = Ops.Queued; intent })

let titles session count =
  for index = 0 to count - 1 do
    stage session (Printf.sprintf "edit-%d" index)
      (Ops.Save_title { uuid = (uuid 101); expected_title = (if index = 0 then "Old" else string_of_int (index - 1));
        title = string_of_int index })
  done

let transactions request = json_items "txs" (member "bodyObject" request)
let ids request = List.map (fun tx -> json_string (member "tx-id" tx)) (transactions request)
let baseline request = Json_util.to_int (member "t-before" (member "bodyObject" request))

let journal request ?count () =
  let txs = transactions request in
  let count = Option.value ~default:(List.length txs) count in
  let before = baseline request in
  let rows = List.mapi (fun index tx -> `Assoc ["t", `Int (before + index + 1);
    "tx-id", member "tx-id" tx; "tx", member "tx" tx]) txs in
  let rec take n = function _ when n = 0 -> [] | [] -> [] | x :: xs -> x :: take (n - 1) xs in
  Json.to_string (`Assoc ["type", `String "tx/batch/ok"; "t-before", `Int before;
    "t", `Int (before + count); "txs", `List (take count rows)])

let ack session request =
  let response = dispatch_json session "completePendingSync" (Json.to_string (`Assoc
    ["id", member "id" request; "status", `Int 200; "body", `String (journal request ())])) in
  if member "ok" response <> `Bool true then fail (Json.to_string response);
  response_result response
let next response = member "pendingSyncRequest" response
let request_from response =
  let request = next response in
  match request with
  | `Assoc fields -> `Assoc (("bodyObject", Json.from_string (json_string (member "body" request))) :: fields)
  | _ -> fail "expected another batch"

let batches_queued_edits_and_acknowledges_every_member () =
  with_session (fun session _ runtime path conn ->
    titles session 3;
    let request = required_pending_request session in
    check_eq (ids request) ["edit-0"; "edit-1"; "edit-2"];
    check_eq (baseline request) 42;
    ignore (ack session request);
    check_eq (Ops.list path) [];
    check_eq (Fixture.title (Datascript.conn_db conn) (uuid 101)) "2";
    check_eq (Fixture.title (Runtime.db runtime) (uuid 101)) "2")

let dependent_creations_share_a_batch () =
  with_session (fun session _ runtime path _ ->
    let page = uuid 1 and parent = uuid 2 and child = uuid 3 in
    stage session "page" (Ops.Create_page { uuid = page; title = "Project"; created_at = 1 });
    stage session "parent" (Ops.Insert_block { uuid = parent; title = "Parent";
      page_uuid = page; parent_uuid = page; order = "a0"; created_at = 2 });
    stage session "child" (Ops.Insert_block { uuid = child; title = "Child";
      page_uuid = page; parent_uuid = parent; order = "a0"; created_at = 3 });
    stage session "edit-child" (Ops.Save_title { uuid = child; expected_title = "Child"; title = "Edited" });
    let request = required_pending_request session in
    check_eq ~msg:"dependencies created earlier in the same batch need no extra round trip"
      (ids request) ["page"; "parent"; "child"; "edit-child"];
    ignore (ack session request);
    check_eq (Ops.list path) [];
    check_eq (Fixture.title (Runtime.db runtime) child) "Edited")

let splits_backlogs_into_bounded_batches () =
  with_session (fun session _ _ path _ ->
    titles session 101;
    let first = required_pending_request session in
    check_eq (List.length (ids first)) 50;
    let second = request_from (ack session first) in
    check_eq (List.length (ids second)) 50;
    check_eq (List.hd (ids second)) "edit-50";
    let third = request_from (ack session second) in
    check_eq (ids third) ["edit-100"];
    ignore (ack session third);
    check_eq (Ops.list path) [])

let size_budget_measures_the_encoded_frame () =
  with_session (fun session _ runtime path conn ->
    let db = Datascript.conn_db conn in
    let db = List.fold_left (fun db index ->
      Datascript.db_with
        [Fixture.add (20 + index) "block/uuid" (Datascript.Uuid (uuid index));
         Fixture.add (20 + index) "block/title" (Datascript.String "Old");
         Fixture.add (20 + index) "block/page" (Datascript.Ref 1);
         Fixture.add (20 + index) "block/parent" (Datascript.Ref 1);
         Fixture.add (20 + index) "block/order" (Datascript.String ("a" ^ string_of_int index))] db) db [1; 2; 3] in
    ignore (Datascript.reset_conn conn db);
    Runtime.rebase runtime 42 [] [];
    let title = String.make 100000 '"' in
    List.iter (fun index -> stage session ("large-" ^ string_of_int index)
      (Ops.Save_title { uuid = uuid index; expected_title = "Old"; title })) [1; 2; 3];
    let first = required_pending_request session in
    check_eq (ids first) ["large-1"; "large-2"];
    check (String.length (json_string (member "body" first)) <= 1_000_000);
    let second = request_from (ack session first) in
    check_eq (ids second) ["large-3"];
    check (String.length (json_string (member "body" second)) <= 1_000_000);
    ignore (ack session second);
    check_eq (Ops.list path) [])

let an_oversized_transaction_stays_local_and_reports_an_error () =
  with_session (fun session _ runtime path _ ->
    let title = String.make 300000 '"' in
    stage session "too-large" (Ops.Save_title { uuid = (uuid 101); expected_title = "Old"; title });
    let response = response_result (dispatch_json session "beginPendingSync" "") in
    check_eq ~msg:"never send a frame above the configured message budget" (next response) `Null;
    check (member "pendingSyncError" response <> `Null);
    check_eq (List.length (Ops.list path)) 1;
    check_eq (Fixture.title (Runtime.db runtime) (uuid 101)) title)

let deletes_are_submitted_alone () =
  with_session (fun session _ _ path _ ->
    titles session 2;
    stage session "delete" (Ops.Delete_blocks { uuids = [(uuid 101)] });
    stage session "page" (Ops.Create_page { uuid = uuid 1; title = "After delete"; created_at = 4 });
    let first = required_pending_request session in
    check_eq (ids first) ["edit-0"; "edit-1"];
    let second = request_from (ack session first) in
    check_eq (ids second) ["delete"];
    let third = request_from (ack session second) in
    check_eq (ids third) ["page"];
    ignore (ack session third);
    check_eq (Ops.list path) [])

let retries_and_cancellation_keep_the_whole_batch () =
  with_session (fun session _ _ _ _ ->
    titles session 3;
    let request = required_pending_request session in
    stage session "late" (Ops.Save_title { uuid = (uuid 101); expected_title = "2"; title = "Late" });
    let retry = response_result (dispatch_json session "completePendingSync"
      (Json.to_string (`Assoc ["id", member "id" request; "error", `String "socket closed"]))) in
    check_eq (member "body" (next retry)) (member "body" request);
    check_eq (ids (request_from retry)) ["edit-0"; "edit-1"; "edit-2"];
    ignore (response_result (dispatch_json session "cancelPendingSync" ""));
    check_eq (ids (required_pending_request session)) ["edit-0"; "edit-1"; "edit-2"; "late"])

let partial_rejection_only_conflicts_the_failed_member () =
  with_session (fun session graph _ path _ ->
    titles session 3;
    let request = required_pending_request session in
    ignore (complete_request session request
      {|{"type":"tx/reject","reason":"db transact failed","retryable":false,"t":43,"success-tx-ids":["edit-0"],"failed-tx-id":"edit-1"}|});
    let state id = (List.find (fun (op : Ops.pending_operation) -> op.operation_id = id) (Ops.list path)).state in
    check_eq (state "edit-0") (Ops.Accepted 43);
    check (match state "edit-1" with Ops.Conflicted _ -> true | _ -> false);
    check_eq (state "edit-2") Ops.Retryable;
    require (Mobile_graph.apply_sync_event graph (journal request ~count:1 ()));
    let tail = required_pending_request session in
    check_eq (ids tail) ["edit-2"];
    ignore (ack session tail);
    check_eq (List.map (fun (op : Ops.pending_operation) -> op.operation_id) (Ops.list path)) ["edit-1"])

let stale_rejection_rebases_and_retries_all_members () =
  with_session (fun session graph _ path _ ->
    titles session 3;
    let request = required_pending_request session in
    ignore (complete_request session request {|{"type":"tx/reject","reason":"stale","t":44}|});
    check_eq (List.map (fun (op : Ops.pending_operation) -> op.state) (Ops.list path))
      [Ops.Retryable; Ops.Retryable; Ops.Retryable];
    require (Mobile_graph.apply_sync_event graph {|{"type":"pull/ok","t":44,"txs":[]}|});
    let retry = required_pending_request session in
    check_eq (ids retry) ["edit-0"; "edit-1"; "edit-2"];
    check_eq (baseline retry) 44;
    ignore (ack session retry);
    check_eq (Ops.list path) [])

let malformed_partial_rejection_preserves_the_active_batch () =
  List.iter (fun body ->
    with_session (fun session _ _ path _ ->
      titles session 3;
      let request = required_pending_request session in
      let response = dispatch_json session "completePendingSync" (Json.to_string (`Assoc
        ["id", member "id" request; "status", `Int 200; "body", `String body])) in
      check_eq ~msg:"invalid batch partitions are rejected before durable state changes" (member "ok" response) (`Bool false);
      check_eq (List.map (fun (op : Ops.pending_operation) -> op.state) (Ops.list path))
        [Ops.Queued; Ops.Queued; Ops.Queued];
      check_eq (member "body" (required_pending_request session)) (member "body" request)))
    [ {|{"type":"tx/reject","reason":"db transact failed","t":43,"success-tx-ids":["edit-1"],"failed-tx-id":"edit-2"}|};
      {|{"type":"tx/reject","reason":"db transact failed","t":43,"success-tx-ids":["edit-0"],"failed-tx-id":"edit-2"}|};
      {|{"type":"tx/reject","reason":"db transact failed","success-tx-ids":["edit-0"],"failed-tx-id":"edit-1"}|} ]

let exhausting_retries_stops_without_losing_batch_members () =
  with_session (fun session _ _ path _ ->
    titles session 3;
    let request = required_pending_request session in
    for attempt = 0 to 3 do
      let result = response_result (dispatch_json session "completePendingSync"
        (Json.to_string (`Assoc ["id", member "id" request; "status", `Int 503; "body", `String "unavailable"]))) in
      if attempt < 3 then check_eq (member "id" (next result)) (member "id" request)
      else check_eq ~msg:"an exhausted retry budget must not restart in a new batch" (next result) `Null
    done;
    check_eq (List.map (fun (op : Ops.pending_operation) -> op.state) (Ops.list path))
      [Ops.Retryable; Ops.Retryable; Ops.Retryable];
    check_eq (ids (required_pending_request session)) ["edit-0"; "edit-1"; "edit-2"])

let cases =
  [ case "queued edits share a batch and ACK" batches_queued_edits_and_acknowledges_every_member;
    case "dependent creations share a batch" dependent_creations_share_a_batch;
    case "backlogs split at 50 operations" splits_backlogs_into_bounded_batches;
    case "byte budget counts the JSON encoded frame" size_budget_measures_the_encoded_frame;
    case "oversized transactions remain local" an_oversized_transaction_stays_local_and_reports_an_error;
    case "deletes are submitted alone" deletes_are_submitted_alone;
    case "retries and cancellation retain every member" retries_and_cancellation_keep_the_whole_batch;
    case "partial rejection settles the accepted prefix" partial_rejection_only_conflicts_the_failed_member;
    case "stale rejection retries the whole batch" stale_rejection_rebases_and_retries_all_members;
    case "malformed rejection preserves the active batch" malformed_partial_rejection_preserves_the_active_batch;
    case "exhausted retries preserve the stopped batch" exhausting_retries_stops_without_losing_batch_members ]
