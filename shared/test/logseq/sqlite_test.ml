open Test_util

module Sqlite = Sqlite
module Model = Cache_model
module Rpc_session = Rpc_session
module Json = Yojson.Basic
module Util = Yojson.Basic.Util
module Transit = Transit_native.Transit.Json
module Value = Transit_core.Json
module Ds = Datascript

let with_database f =
  let path = Filename.temp_file "logseq-sqlite-test" ".sqlite" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> f path)

let raises_invalid_arg f =
  match f () with
  | exception Invalid_argument _ -> ()
  | _ -> fail "expected Invalid_argument"

let raises_failure f =
  match f () with
  | exception Failure _ -> ()
  | _ -> fail "expected Failure"

let raises_failure_substring needle f =
  match f () with
  | exception Failure message ->
    check ~msg:message
      (try
         ignore (Str.search_forward (Str.regexp_string needle) message 0);
         true
       with Not_found -> false)
  | _ -> fail "expected Failure"

let session_roundtrip_and_closed_access () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    let text = "Unicode \xE8\x8D\x89\xE7\xA8\xBF\x00tail" in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        Sqlite.store_string session "metadata" text;
        check_eq (Sqlite.restore_string session "metadata") (Some text));
    Sqlite.close session;
    raises_invalid_arg (fun () -> Sqlite.restore_string session "metadata");
    let reopened = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close reopened)
      (fun () ->
        check_eq (Sqlite.restore_string reopened "metadata") (Some text)))

let invalid_envelope_is_a_cache_miss () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        Sqlite.store_raw session
          [
            ("broken", "not transit");
            ("legacy", Marshal.to_string "old" []);
            ( "future",
              "[\"^ \",\"~:format-version\",2,\"~:value-type\",\"~:string\",\"~:value\",\"future\"]" );
          ];
        check_eq (Sqlite.restore_string session "broken") None;
        check_eq (Sqlite.restore_string session "legacy") None;
        check_eq (Sqlite.restore_string session "future") None))

let opening_errors_preserve_failure_contract () =
  with_database (fun path ->
    raises_failure (fun () ->
      Sqlite.open_session (Filename.concat path "child.sqlite") |> ignore))

let sqlite_errors_preserve_failure_contract () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        raises_failure_substring "no such table" (fun () ->
          Sqlite.execute session "INSERT INTO missing_table VALUES (1)");
        raises_failure_substring "no such table" (fun () ->
          Sqlite.with_statement session "SELECT * FROM missing_table"
            (fun _ -> ())
          |> ignore);
        Sqlite.store_string session "after-error" "usable";
        check_eq (Sqlite.restore_string session "after-error") (Some "usable")))

let datascript_storage_roundtrip_and_format () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    let storage = Sqlite.storage session in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        storage.Ds.storage_store
          [ ("tail", Ds.Storage_tail []) ];
        check_eq
          (storage.storage_restore "tail")
          (Some (Ds.Storage_tail []));
        check_eq (Sqlite.restore_string session "tail") None;
        Sqlite.store_string session "metadata" "value";
        check_eq (storage.storage_restore "metadata") None;
        Sqlite.store_raw session
          [ ("legacy-tail", Marshal.to_string (Ds.Storage_tail []) []) ];
        check_eq (storage.storage_restore "legacy-tail") None;
        check_eq
          (Sqlite.decode_envelope "datascript-storage"
             (Option.value ~default:"" (Sqlite.restore_raw session "tail")))
          (Some "[]");
        storage.storage_delete [ "tail" ];
        check_eq (storage.storage_restore "tail") None;
        check_eq
          (storage.storage_list_addresses ())
          [ "metadata"; "legacy-tail" ]))

let cached_block_survives_reopening () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    let cache = Model.create (Some (Sqlite.storage session)) in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        Model.cache_local_message cache "local-persisted"
          "Persisted offline capture" 1776000000000;
        Model.upsert_statuses cache
          [
            {
              Model.uuid = "status-waiting";
              ident = Some "user.status/waiting";
              title = "Waiting";
              icon_type = Some "tabler-icon";
              icon_id = Some "clock";
              icon_color = Some "#7c3aed";
            };
          ]);
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        let cache = Model.create (Some (Sqlite.storage session)) in
        let block = Model.read_block cache "local-persisted" in
        (match block with
         | Some block ->
           check_eq (Some block.title) (Some "Persisted offline capture");
           check_eq (Some block.sync_status) (Some "pending");
           check (String.starts_with ~prefix:"journal/" block.page_id)
         | None -> fail "missing block");
        check_eq
          (List.map (fun (s : Model.status) -> s.title)
             (Model.all_statuses cache))
          [ "Waiting" ];
        check_eq
          (List.map (fun (s : Model.status) -> s.icon_color)
             (Model.all_statuses cache))
          [ Some "#7c3aed" ]))

let migration_preserves_metadata () =
  with_database (fun source_path ->
    with_database (fun destination_path ->
      let source = Sqlite.open_session source_path in
      let destination = Sqlite.open_session destination_path in
      Fun.protect
        ~finally:(fun () ->
          Sqlite.close source;
          Sqlite.close destination)
        (fun () ->
          Sqlite.store_string source "catalog" "{\"graphs\":[]}";
          Model.cache_local_asset
            (Model.create (Some (Sqlite.storage source)))
            "legacy-asset" "photo.jpg" "jpg" 4 "abcd" "Assets/photo.jpg" 1
            None;
          Sqlite.migrate_datascript_storage source destination;
          check_eq
            (List.length
               (Model.pending_blocks
                  (Model.create (Some (Sqlite.storage destination)))))
            1;
          check_eq
            (Model.pending_blocks
               (Model.create (Some (Sqlite.storage source))))
            [];
          check_eq (Sqlite.restore_string source "catalog")
            (Some "{\"graphs\":[]}"))))

let failed_migration_retains_source () =
  with_database (fun source_path ->
    with_database (fun destination_path ->
      let source = Sqlite.open_session source_path in
      let destination = Sqlite.open_session destination_path in
      Fun.protect
        ~finally:(fun () ->
          Sqlite.close source;
          Sqlite.close destination)
        (fun () ->
          Model.cache_local_message
            (Model.create (Some (Sqlite.storage source)))
            "pending" "Keep me" 1;
          Sqlite.execute destination
            "CREATE TRIGGER reject_all BEFORE INSERT ON kvs BEGIN SELECT RAISE(ABORT, 'rejected'); END";
          raises_failure (fun () ->
            Sqlite.migrate_datascript_storage source destination);
          check_eq
            (List.length
               (Model.pending_blocks
                  (Model.create (Some (Sqlite.storage source)))))
            1)))

let failed_write_rolls_back_the_whole_batch () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        Sqlite.execute session
          "CREATE TRIGGER reject_bad BEFORE INSERT ON kvs WHEN NEW.address = 'bad' BEGIN SELECT RAISE(ABORT, 'rejected'); END";
        raises_failure_substring "rejected" (fun () ->
          Sqlite.store_raw session [ ("first", "one"); ("bad", "two") ]);
        check_eq (Sqlite.restore_raw session "first") None;
        Sqlite.store_raw session [ ("next", "three") ];
        check_eq (Sqlite.restore_raw session "next") (Some "three")))

let metadata_has_versioned_transit_envelope () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        Sqlite.store_string session "metadata" "value";
        check_eq
          (Transit.of_string
             (Option.value ~default:""
                (Sqlite.restore_raw session "metadata")))
          (Value.Map
             [
               (Value.Keyword "format-version", Value.Int 1);
               (Value.Keyword "value-type", Value.Keyword "string");
               (Value.Keyword "value", Value.String "value");
             ])))

let rpc_restart_isolates_the_open_graph () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        let app =
          Rpc_session.create_session
            {
              Session_types.default_options with
              storage = Some (Sqlite.storage session);
            }
        in
        ignore
          (Rpc_session.call app
             "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"send\",\"payload\":\"{\\\"text\\\":\\\"Survives restart\\\",\\\"uuid\\\":\\\"local-restart\\\",\\\"now\\\":1776000000000}\"}}"));
    let session = Sqlite.open_session path in
    let remote : Model.block =
      {
        uuid = "remote-existing";
        title = "Existing server block";
        page_id = "journal/2026-04-13";
        parent_id = None;
        order = None;
        created_at = 1776000000001;
        updated_at = 1776000000001;
        sync_status = "synced";
        tags = [];
        references = [];
        breadcrumbs = [];
        priority = None;
        status = None;
        is_asset = false;
        asset_type = None;
        asset_size = None;
        asset_checksum = None;
        local_path = None;
        journal = None;
      }
    in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        let app =
          Rpc_session.create_session
            {
              Session_types.default_options with
              storage = Some (Sqlite.storage session);
              graph_blocks = Some (fun () -> Some [ remote ]);
            }
        in
        Model.upsert_journal_page
          (Rpc_session.state app).model "journal/2026-04-13" 20260413 "";
        let response =
          Json.from_string
            (Rpc_session.call app
               "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}")
        in
        let blocks =
          Util.to_list
            (Util.member "blocks" (Util.member "result" response))
        in
        let uuids =
          List.map
            (fun block -> Util.to_string (Util.member "uuid" block))
            blocks
        in
        check (not (List.exists (fun uuid -> uuid = "local-restart") uuids));
        check (List.exists (fun uuid -> uuid = "remote-existing") uuids)))

let catalog =
  "{\"graphs\":[{\"graph-id\":\"plain-graph\",\"graph-name\":\"Sync 2\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}"

let catalog_survives_reopening_and_configures_rpc () =
  with_database (fun path ->
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        Sqlite.store_string session "logseq/graph-catalog/v1" catalog);
    let session = Sqlite.open_session path in
    Fun.protect
      ~finally:(fun () -> Sqlite.close session)
      (fun () ->
        check_eq
          (Sqlite.restore_string session "logseq/graph-catalog/v1")
          (Some catalog);
        let app =
          Rpc_session.create_session
            {
              Session_types.default_options with
              storage = Some (Sqlite.storage session);
              load_graph_catalog =
                Some
                  (fun () ->
                    Sqlite.restore_string session
                      "logseq/graph-catalog/v1");
            }
        in
        let response =
          Json.from_string
            (Rpc_session.call app
               "{\"apiVersion\":1,\"method\":\"dispatch\",\"params\":{\"action\":\"configure\",\"payload\":\"{\\\"baseUrl\\\":\\\"http://127.0.0.1:8787\\\",\\\"graphId\\\":\\\"plain-graph\\\",\\\"token\\\":\\\"\\\"}\"}}")
        in
        let result = Util.member "result" response in
        check_eq
          (Util.to_string (Util.member "graphName" result))
          "Sync 2";
        check_eq
          (List.length (Util.to_list (Util.member "graphs" result)))
          1))

let cases =
  [
    case "session roundtrip and closed access"
      session_roundtrip_and_closed_access;
    case "invalid envelope is a cache miss" invalid_envelope_is_a_cache_miss;
    case "opening errors preserve failure contract"
      opening_errors_preserve_failure_contract;
    case "sqlite errors preserve failure contract"
      sqlite_errors_preserve_failure_contract;
    case "datascript storage roundtrip and format"
      datascript_storage_roundtrip_and_format;
    case "cached block survives reopening" cached_block_survives_reopening;
    case "migration preserves metadata" migration_preserves_metadata;
    case "failed migration retains source" failed_migration_retains_source;
    case "failed write rolls back the whole batch"
      failed_write_rolls_back_the_whole_batch;
    case "metadata has versioned transit envelope"
      metadata_has_versioned_transit_envelope;
    case "rpc restart isolates the open graph" rpc_restart_isolates_the_open_graph;
    case "catalog survives reopening and configures rpc"
      catalog_survives_reopening_and_configures_rpc;
  ]
