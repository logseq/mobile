open Test_util

module Ds = Datascript
module V = Transit_core.Json
module Transit = Transit_native.Transit.Json
module Mobile = Mobile_graph
module Runtime = Graph_runtime
module Ops = Pending_ops

let page = "00000000-0000-4000-8000-000000000001"
let block = "00000000-0000-4000-8000-000000000002"
let child = "00000000-0000-4000-8000-000000000003"
let open_payload dir encrypted =
  let fields = Yojson.Basic.Util.to_assoc
      (Yojson.Basic.from_string (Mobile_graph_test.open_payload dir encrypted)) in
  Yojson.Basic.to_string (`Assoc (("graphId", `String "plain-1") :: List.remove_assoc "graphId" fields))
let lookup uuid = V.Array [ V.Keyword "block/uuid"; V.Uuid uuid ]
let add e a v = V.Array [ V.Keyword "db/add"; e; V.Keyword a; v ]
let retract e a v = V.Array [ V.Keyword "db/retract"; e; V.Keyword a; v ]
let ok = Mobile_graph_test.expect_ok

let row ?id t items =
  `Assoc
    ([ "t", `Int t; "tx", `String (Transit.to_string (V.Array items));
       "outliner-op", `String "save-block" ]
     @ match id with None -> [] | Some id -> [ "tx-id", `String id ])

let message ?before ?(typ = "pull/ok") t rows =
  Yojson.Basic.to_string
    (`Assoc
       ([ "type", `String typ; "t", `Int t; "txs", `List rows ]
        @ match before with None -> [] | Some t -> [ "t-before", `Int t ]))

let with_graph ?(encrypted = false) f =
  Mobile_graph_test.with_directory (fun dir ->
    let path = Filename.concat dir "graph.sqlite" in
    Graph_sqlite.prepare_staging path;
    let db =
      Ds.db_with
        [ Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid page);
          Ds.Add (Ds.Entity_id 1, "block/title", Ds.String "Page");
          Ds.Add (Ds.Entity_id 10, "block/uuid", Ds.Uuid block);
          Ds.Add (Ds.Entity_id 10, "block/title", Ds.String "Old");
          Ds.Add (Ds.Entity_id 10, "block/page", Ds.Ref 1);
          Ds.Add (Ds.Entity_id 10, "block/parent", Ds.Ref 1);
          Ds.Add (Ds.Entity_id 10, "block/order", Ds.String "a0") ]
        (Ds.empty_db ~schema:Graph_runtime_test.schema
           ~storage:(Graph_store.storage path) ())
    in
    ignore (Ds.store db);
    ok (Sync_checkpoint.save_checkpoint_atomic (Filename.concat dir "checkpoint")
          (Sync_checkpoint.create "plain-1" "1" 42));
    let host =
      Mobile.create
        { require_key = (fun _ -> Ok ());
          encrypt_title = (fun _ s -> Ok ("cipher:" ^ s));
          decrypt_title = (fun _ s -> Sync_session_test.decrypt s) }
    in
    ok (Mobile.open_graph host (open_payload dir encrypted));
    let opened = Option.get !(host.current) in
    (* Opening a graph can queue today's journal; isolate the edits below. *)
    List.iter (fun (op : Ops.pending_operation) -> Ops.remove path op.operation_id)
      (Ops.list path);
    Runtime.rebase opened.read_runtime 42 [] [];
    f dir path host opened)

let title db uuid =
  match Ds.entity db (Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid)) with
  | None -> None
  | Some e ->
    (match Ds.Entity.entity_attr_raw e "block/title" with
     | Some (Ds.One_value (Ds.String s)) -> Some s
     | _ -> None)

let save host id before after =
  ok (Mobile.stage host
        { Ops.operation_id = id; base_t = Option.get (Mobile.sync_cursor host);
          state = Ops.Queued;
          intent = Ops.Save_title { uuid = block; expected_title = before; title = after } })

let journal_applies_canonical_rows_and_stable_refs () =
  with_graph (fun _ path host opened ->
    ok (Mobile.apply_sync_event host
          (message 44
             [ row 43 [ retract (lookup block) "block/title" (V.String "Old");
                        add (lookup block) "block/title" (V.String "Remote") ];
               row 44 [ add (V.String child) "block/uuid" (V.Uuid child);
                        add (V.String child) "block/title" (V.String "Child");
                        add (V.String child) "block/parent" (lookup block) ] ]));
    check_eq (Mobile.sync_cursor host) (Some 44);
    check_eq (title (Ds.conn_db opened.conn) block) (Some "Remote");
    let db = ok (Graph_store.restore_db path) in
    check_eq (title db child) (Some "Child");
    let e = Option.get (Ds.entity db (Ds.Lookup_ref ("block/uuid", Ds.Uuid child))) in
    let parent = Option.get (Ds.entid db "block/uuid" (Ds.Uuid block)) in
    check_eq (Ds.Entity.entity_attr_raw e "block/parent")
      (Some (Ds.One_value (Ds.Ref parent))))

let overlay_replays_stored_datoms_and_survives_restart () =
  with_graph (fun dir path host opened ->
    save host "local" "Old" "Mine";
    let operation = List.hd (Mobile.pending_operations host) in
    let original_wire = ok (Mobile.prepare_sync host operation) in
    ok (Mobile.apply_sync_event host
          (message 43 [ row 43 [ add (lookup block) "block/title" (V.String "Remote") ] ]));
    check_eq (title (Ds.conn_db opened.conn) block) (Some "Remote");
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Mine");
    check_eq (title (ok (Graph_store.restore_db path)) block) (Some "Remote");
    let pending = List.hd (Mobile.pending_operations host) in
    check_eq (ok (Mobile.prepare_sync host pending)) original_wire;
    ok (Mobile.open_graph host (open_payload dir false));
    let reopened = Option.get !(host.current) in
    check_eq (title (Runtime.db reopened.read_runtime) block) (Some "Mine");
    check (List.exists (fun (op : Ops.pending_operation) -> op.operation_id = "local")
             (Mobile.pending_operations host)))

let own_ack_keeps_server_corrections_and_only_confirms_named_tx () =
  with_graph (fun _ path host opened ->
    save host "first" "Old" "Mine";
    save host "second" "Mine" "Later";
    ok (Mobile.apply_sync_event host
          (message ~typ:"tx/batch/ok" ~before:42 43
             [ row ~id:"first" 43
                 [ add (lookup block) "block/title" (V.String "Server corrected") ] ]));
    check_eq (title (Ds.conn_db opened.conn) block) (Some "Server corrected");
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Later");
    check_eq (List.map (fun (op : Ops.pending_operation) -> op.operation_id) (Ops.list path))
      [ "second" ];
    ok (Mobile.apply_sync_event host
          (message ~typ:"tx/batch/ok" ~before:43 44
             [ row ~id:"second" 44
                 [ add (lookup block) "block/title" (V.String "Canonical later") ] ]));
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Canonical later");
    check_eq (Ops.list path) [])

let malformed_journal_does_not_advance_or_partially_commit () =
  with_graph (fun _ path host opened ->
    check_error (Mobile.apply_sync_event host
                   (message 44
                      [ row 43 [ add (lookup block) "block/title" (V.String "Do not commit") ];
                        `Assoc [ "t", `Int 44; "tx", `String "invalid transit" ] ]));
    check_eq (Mobile.sync_cursor host) (Some 42);
    check_eq (title (Ds.conn_db opened.conn) block) (Some "Old");
    check_eq (title (ok (Graph_store.restore_db path)) block) (Some "Old"))

let missing_journal_ref_fails_without_consuming_the_row () =
  with_graph (fun _ _ host opened ->
    check_error (Mobile.apply_sync_event host
                   (message 43 [ row 43 [ add (lookup block) "block/parent" (lookup child) ] ]));
    check_eq (Mobile.sync_cursor host) (Some 42);
    check_eq (title (Ds.conn_db opened.conn) block) (Some "Old"))

let duplicate_rows_and_empty_windows_follow_the_watermark () =
  with_graph (fun _ _ host opened ->
    let first = row 43 [ add (lookup block) "block/title" (V.String "Once") ] in
    ok (Mobile.apply_sync_event host (message 43 [ first ]));
    save host "pending" "Once" "Mine";
    ok (Mobile.apply_sync_event host (message 43 [ first ]));
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Mine");
    ok (Mobile.apply_sync_event host (message 44 []));
    check_eq (Mobile.sync_cursor host) (Some 44);
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Mine"))

let encrypted_journal_is_decrypted_before_overlay_and_persistence () =
  with_graph ~encrypted:true (fun _ path host opened ->
    save host "local" "Old" "Mine";
    ok (Mobile.apply_sync_event host
          (message 43 [ row 43 [ add (lookup block) "block/title" (V.String "cipher:Remote") ] ]));
    check_eq (title (ok (Graph_store.restore_db path)) block) (Some "Remote");
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Mine");
    check_error (Mobile.apply_sync_event host
                   (message 44 [ row 44 [ add (lookup block) "block/title" (V.String "bad ciphertext") ] ]));
    check_eq (Mobile.sync_cursor host) (Some 43))

let deleted_dependency_defers_the_whole_pending_entry () =
  with_graph (fun _ path host opened ->
    save host "local" "Old" "Mine";
    ok (Mobile.apply_sync_event host
          (message 43 [ row 43 [ V.Array [ V.Keyword "db/retractEntity"; lookup block ] ] ]));
    check_eq (title (Runtime.db opened.read_runtime) block) None;
    check_eq (List.map (fun (op : Ops.pending_operation) -> op.operation_id) (Ops.list path)) [ "local" ];
    ok (Mobile.apply_sync_event host
          (message 44 [ row 44 [ add (V.String block) "block/uuid" (V.Uuid block);
                                 add (V.String block) "block/title" (V.String "Returned") ] ]));
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Mine"))

let http_ack_applies_the_journal_through_the_pending_pump () =
  with_graph (fun _ path host opened ->
    save host "upload" "Old" "Mine";
    let session = Rpc_session.create_session
        { Rpc_session.default_options with
          load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
          sync_cursor = Some (fun () -> Mobile.sync_cursor host);
          stage_operation = Some (Mobile.stage host);
          prepare_operation = Some (Mobile.prepare_sync host);
          pending_operations = Some (fun () -> Mobile.pending_operations host);
          apply_sync_event = Some (Mobile.apply_sync_event host) }
    in
    ignore (Rpc_test.configure_plain_session session);
    let response = Rpc_test.dispatch_json session "beginPendingSync" "" in
    let request = Option.get (Rpc_test.pending_request response) in
    let id = Yojson.Basic.Util.to_int (Yojson.Basic.Util.member "id" request) in
    let body = message ~typ:"tx/batch/ok" ~before:42 43
        [ row ~id:"upload" 43 [ add (lookup block) "block/title" (V.String "Corrected") ] ] in
    let completion = Yojson.Basic.to_string
        (`Assoc [ "id", `Int id; "status", `Int 200; "body", `String body ]) in
    let result = Rpc_test.dispatch_json session "completePendingSync" completion in
    check_eq (Yojson.Basic.Util.member "error" result) `Null;
    check_eq (Mobile.sync_cursor host) (Some 43);
    check_eq (title (Ds.conn_db opened.conn) block) (Some "Corrected");
    check_eq (title (Runtime.db opened.read_runtime) block) (Some "Corrected");
    check_eq (Ops.list path) [])

let snapshot_import_reads_schema_and_row_count_from_the_snapshot () =
  Mobile_graph_test.with_directory (fun dir ->
    let db = ok (Graph_bootstrap.database "graph" false (fun s -> Ok s)) in
    let outer = Yojson.Basic.from_string (Mobile_graph_test.snapshot_request dir false db) in
    let fields = Yojson.Basic.Util.to_assoc outer in
    let payload = Yojson.Basic.to_string (`Assoc
        (("metadataBody", `String "{\"ok\":true,\"url\":\"snapshot\",\"t\":12}")
         :: List.remove_assoc "metadataBody" fields)) in
    let host = Mobile_graph_test.host () in
    ok (Mobile.import_snapshot host payload);
    let opened = Option.get !(host.current) in
    check_eq opened.state.schema_version Graph_bootstrap.schema_version;
    check_eq (Mobile.sync_cursor host) (Some 12))

let rejected_uploads_follow_dev_retry_and_overlay_rules () =
  List.iter (fun retryable ->
    with_graph (fun _ path host opened ->
      save host "rejected" "Old" "Mine";
      let session = Rpc_session.create_session
          { Rpc_session.default_options with
            load_graph_catalog = Some (fun () -> Some Rpc_test.plain_graph_catalog);
            sync_cursor = Some (fun () -> Mobile.sync_cursor host);
            stage_operation = Some (Mobile.stage host);
            prepare_operation = Some (Mobile.prepare_sync host);
            pending_operations = Some (fun () -> Mobile.pending_operations host);
            apply_sync_event = Some (Mobile.apply_sync_event host) } in
      ignore (Rpc_test.configure_plain_session session);
      let request = Rpc_test.required_pending_request session in
      ignore (Rpc_test.complete_request session request
                (Yojson.Basic.to_string (`Assoc
                   [ "type", `String "tx/reject"; "reason", `String "db transact failed";
                     "failed-tx-id", `String "rejected"; "retryable", `Bool retryable; "t", `Int 42 ])));
      check_eq (title (Runtime.db opened.read_runtime) block) (Some (if retryable then "Mine" else "Old"));
      let pending = List.hd (Ops.list path) in
      check (match pending.state with
             | Ops.Retryable -> retryable
             | Ops.Conflicted _ -> not retryable
             | _ -> false))) [ false; true ]

let a_late_socket_frame_cannot_write_into_another_graph () =
  with_graph (fun _ _ host opened ->
    let fields = Yojson.Basic.Util.to_assoc (Yojson.Basic.from_string
        (message 43 [ row 43 [ add (lookup block) "block/title" (V.String "Wrong graph") ] ])) in
    let payload = Yojson.Basic.to_string (`Assoc (("graphId", `String "another-graph") :: fields)) in
    check_error (Mobile.apply_sync_event host payload);
    check_eq (Mobile.sync_cursor host) (Some 42);
    check_eq (title (Ds.conn_db opened.conn) block) (Some "Old"))

let cases =
  [ case "canonical journal rows and stable refs" journal_applies_canonical_rows_and_stable_refs;
    case "stored overlay survives remote writes and restart" overlay_replays_stored_datoms_and_survives_restart;
    case "ACK applies corrections and confirms only named tx" own_ack_keeps_server_corrections_and_only_confirms_named_tx;
    case "malformed journal is atomic" malformed_journal_does_not_advance_or_partially_commit;
    case "missing ref does not consume journal" missing_journal_ref_fails_without_consuming_the_row;
    case "duplicate and empty journal windows" duplicate_rows_and_empty_windows_follow_the_watermark;
    case "encrypted journal and plaintext persistence" encrypted_journal_is_decrypted_before_overlay_and_persistence;
    case "deleted dependency defers whole pending entry" deleted_dependency_defers_the_whole_pending_entry;
    case "HTTP ACK applies journal through pending pump" http_ack_applies_the_journal_through_the_pending_pump;
    case "dev snapshot without added metadata" snapshot_import_reads_schema_and_row_count_from_the_snapshot;
    case "rejected uploads follow dev retry rules" rejected_uploads_follow_dev_retry_and_overlay_rules;
    case "late socket frame stays scoped to its graph" a_late_socket_frame_cannot_write_into_another_graph ]
