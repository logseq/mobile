open Test_util

module Mobile = Mobile_graph
module Database = Mobile_database
module Sqlite = Sqlite
module Model = Cache_model
module Runtime = Graph_runtime
module Cards = Flashcards
module Store = Graph_store
module Sqlite_store = Graph_sqlite
module Bootstrap = Graph_bootstrap
module Checkpoint = Sync_checkpoint
module Sync = Sync_session
module Json = Yojson.Basic
module Value = Transit_core.Json
module Transit = Transit_native.Transit.Json
module Ds = Datascript

let expect_ok result =
  match result with
  | Ok value -> value
  | Error message -> fail message

let error result = Result.is_error result

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path

let with_directory f =
  let path = Filename.temp_file "logseq-mobile-graph" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)

let database () =
  Ds.empty_db ~schema:Bootstrap.native_schema
    ~storage:(Ds.memory_storage ())
    ()

let prepare_graph dir =
  let active = Filename.concat dir "graph.sqlite" in
  let saved = Filename.concat dir "checkpoint" in
  Sqlite_store.prepare_staging active;
  ignore
    (Ds.store
       (Ds.empty_db ~schema:Bootstrap.native_schema
          ~storage:(Store.storage active) ()));
  expect_ok
    (Checkpoint.save_checkpoint_atomic saved (Checkpoint.create "graph" "1" 7))

let open_fields dir encrypted =
  [
    ("graphId", `String "graph");
    ("activePath", `String (Filename.concat dir "graph.sqlite"));
    ("checkpointPath", `String (Filename.concat dir "checkpoint"));
    ("isEncrypted", `Bool encrypted);
  ]

let json_object fields = Json.to_string (`Assoc fields)
let open_payload dir encrypted = json_object (open_fields dir encrypted)

let crypto require_key : Mobile.graph_crypto =
  {
    require_key;
    encrypt_title = (fun _ title -> Ok title);
    decrypt_title = (fun _ title -> Ok title);
  }

let host () = Mobile.create (crypto (fun _ -> Ok ()))

let expect_opened value =
  match value with
  | Some value -> value
  | None -> fail "graph was not opened"

let asset_path_resolution_follows_the_current_graph () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = host () in
      let relative = "assets/photo.jpg" in
      let absolute = Filename.concat dir "photo.jpg" in
      check_eq (Mobile.resolve_asset_path host relative) relative;
      check_eq (Mobile.resolve_asset_path host absolute) absolute;
      expect_ok (Mobile.open_graph host (open_payload dir false));
      check_eq
        (Mobile.resolve_asset_path host relative)
        (Filename.concat dir relative);
      check_eq (Mobile.resolve_asset_path host absolute) absolute;
      host.current := None;
      check_eq (Mobile.resolve_asset_path host relative) relative)

let unopened_host_preserves_query_and_command_defaults () =
  let host = host () in
  check_eq (Mobile.sync_cursor host) None;
  check_eq (Mobile.blocks host) None;
  check_eq (Mobile.authoritative_blocks host) None;
  check_eq (Mobile.sidebar_pages host) None;
  check_eq (Mobile.tag_pages host) None;
  check_eq (Mobile.blocks_for_page host "missing") None;
  check_eq (Mobile.node_destination host "missing") None;
  check_eq (Mobile.objects_for_tag host "missing") None;
  check_eq (Mobile.references_for_node host "missing") None;
  check (not (Mobile.node_is_tag host "missing"));
  check (not (Mobile.node_is_property host "missing"));
  check_eq
    (Mobile.normalize_titles host "missing" [ "one"; "two" ])
    ([ "one"; "two" ], []);
  check_eq (Mobile.search host "anything") [];
  check_eq (Mobile.due_flashcards host 0) [];
  check_eq (Mobile.pending_operations host) [];
  check_eq (Mobile.journal_page_uuid host 20260916) None;
  check (not (Mobile.has_older_journals host));
  Mobile.load_older_journals host;
  check_eq
    (Mobile.set_page_favorite host "missing" true "favorite" 0)
    (Error "graph runtime is not open");
  check_eq
    (Mobile.delete_page host "missing" "delete" 0)
    (Error "graph runtime is not open");
  check_eq
    (Mobile.review_flashcard host "missing" Cards.Good 0 "review")
    (Error "graph runtime is not open")

let unopened_graph_models_are_isolated_and_do_not_open_projections () =
  let database = Database.create (host ()) in
  Fun.protect
    ~finally:(fun () -> Database.close database)
    (fun () ->
      let first_model = Database.model_for_graph database "first" in
      Model.cache_local_message first_model "draft" "Local" 100;
      check
        (Option.is_some (Model.read_block first_model "draft"));
      check_eq
        (Model.read_block (Database.model_for_graph database "missing") "draft")
        None;
      check_eq !(database.projection) None)

let graph_projection_migrates_storage_but_keeps_catalog_metadata () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = host () in
      let database = Database.create host in
      let catalog =
        Database.open_catalog database (Filename.concat dir "catalog.sqlite")
      in
      Fun.protect
        ~finally:(fun () -> Database.close database)
        (fun () ->
          let legacy = Model.create (Some (Sqlite.storage catalog)) in
          Model.cache_local_message legacy "draft" "From catalog" 100;
          Sqlite.store_string catalog "catalog-marker" "keep";
          expect_ok (Mobile.open_graph host (open_payload dir false));
          let projection_model =
            Database.model_for_graph database "graph"
          in
          check_eq
            (Option.map
               (fun (block : Model.block) -> block.title)
               (Model.read_block projection_model "draft"))
            (Some "From catalog");
          check_eq
            (Sqlite.restore_string catalog "catalog-marker")
            (Some "keep");
          check_eq (Sqlite.list_addresses catalog) [ "catalog-marker" ];
          check
            (Sys.file_exists (Filename.concat dir "projection.sqlite"))))

let existing_projection_is_reused_without_reimporting_catalog () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = host () in
      let database = Database.create host in
      let catalog =
        Database.open_catalog database (Filename.concat dir "catalog.sqlite")
      in
      Fun.protect
        ~finally:(fun () -> Database.close database)
        (fun () ->
          expect_ok (Mobile.open_graph host (open_payload dir false));
          let first_model = Database.model_for_graph database "graph" in
          let first_projection = expect_opened !(database.projection) in
          Model.cache_local_message first_model "draft" "Keep projection" 100;
          check_eq
            (Model.read_block
               (Database.model_for_graph database "another-graph")
               "draft")
            None;
          check (not !(first_projection.closed));
          Model.cache_local_message
            (Model.create (Some (Sqlite.storage catalog)))
            "draft" "Do not overwrite" 100;
          let reopened = Database.model_for_graph database "graph" in
          check !(first_projection.closed);
          check_eq
            (Option.map
               (fun (block : Model.block) -> block.title)
               (Model.read_block reopened "draft"))
            (Some "Keep projection");
          check (Sqlite.list_addresses catalog <> [])))

let failed_catalog_open_leaves_no_closed_session_installed () =
  with_directory (fun dir ->
      let database = Database.create (host ()) in
      let previous =
        Database.open_catalog database (Filename.concat dir "catalog.sqlite")
      in
      Fun.protect
        ~finally:(fun () -> Database.close database)
        (fun () ->
          check
            (match
               Database.open_catalog database
                 (Filename.concat dir "missing/catalog.sqlite")
             with
             | exception Failure _ -> true
             | _ -> false);
          check !(previous.closed);
          check_eq !(database.catalog) None;
          check_eq !(database.projection) None))

let catalog_reopen_closes_connections_and_clears_the_open_graph () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = host () in
      let database = Database.create host in
      let first_catalog =
        Database.open_catalog database (Filename.concat dir "first.sqlite")
      in
      Fun.protect
        ~finally:(fun () -> Database.close database)
        (fun () ->
          expect_ok (Mobile.open_graph host (open_payload dir false));
          ignore (Database.model_for_graph database "graph");
          let projection = expect_opened !(database.projection) in
          let second_catalog =
            Database.open_catalog database
              (Filename.concat dir "second.sqlite")
          in
          check !(first_catalog.closed);
          check !(projection.closed);
          check (not !(second_catalog.closed));
          check_eq !(database.projection) None;
          check_eq !(host.current) None))

let opened_host_reads_live_runtime_and_observes_close () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = host () in
      expect_ok (Mobile.open_graph host (open_payload dir false));
      let opened = expect_opened !(host.current) in
      let current = opened.read_runtime in
      check_eq (Mobile.sync_cursor host) (Some 7);
      check_eq (Mobile.blocks host) (Some (Runtime.blocks current));
      check_eq (Mobile.authoritative_blocks host) (Some []);
      check_eq
        (Mobile.sidebar_pages host)
        (Some (Runtime.sidebar_pages current));
      check_eq (Mobile.tag_pages host) (Some (Runtime.tag_pages current));
      check_eq (Mobile.blocks_for_page host "missing") (Some []);
      check_eq (Mobile.objects_for_tag host "missing") (Some []);
      check_eq (Mobile.references_for_node host "missing") (Some []);
      check_eq (Mobile.search host "missing") (Runtime.search current "missing");
      check_eq
        (Mobile.due_flashcards host 0)
        (Runtime.due_flashcards current 0);
      check_eq
        (Mobile.pending_operations host)
        (Runtime.pending_operations current);
      let operation =
        expect_opened (List.nth_opt (Mobile.pending_operations host) 0)
      in
      host.current := None;
      check_eq (Mobile.blocks host) None;
      check_eq (Mobile.stage host operation)
        (Error "graph runtime is not open");
      check_eq
        (Mobile.prepare_sync host operation)
        (Error "graph runtime is not open"))

let event_payload event data =
  json_object
    [ ("type", `String event); ("data", `String (Transit.to_string data)) ]

let change_event _before after =
  json_object [ "type", `String "pull/ok"; "t", `Int after; "txs", `List [] ]

let snapshot_request dir encrypted db =
  let rows = expect_ok (Bootstrap.snapshot_rows db) in
  let download = Filename.concat dir "snapshot" in
  let channel = open_out_bin download in
  let metadata =
    json_object
      [
        ("ok", `Bool true);
        ("url", `String "snapshot");
        ("t", `Int 12);
        ("schema-version", `String "1");
        ("row-count", `Int (List.length rows));
      ]
  in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel (Bootstrap.frame_rows rows));
  json_object
    (open_fields dir encrypted
    @ [
        ("metadataBody", `String metadata);
        ("downloadPath", `String download);
      ])

let open_validates_checkpoint_before_accessing_keys () =
  with_directory (fun dir ->
      let calls = ref 0 in
      let host =
        Mobile.create
          (crypto (fun _ ->
               incr calls;
               Error "locked"))
      in
      let saved = Filename.concat dir "checkpoint" in
      check_eq
        (Mobile.open_graph host (open_payload dir true))
        (Error "graph checkpoint is missing");
      expect_ok
        (Checkpoint.save_checkpoint_atomic saved
           (Checkpoint.create "other" "1" 7));
      check_eq
        (Mobile.open_graph host (open_payload dir true))
        (Error "graph checkpoint belongs to another graph");
      check_eq !calls 0;
      check_eq !(host.current) None)

let plaintext_open_restores_cursor_search_and_today_without_key_access () =
  with_directory (fun dir ->
      prepare_graph dir;
      let calls = ref 0 in
      let host =
        Mobile.create
          (crypto (fun _ ->
               incr calls;
               Error "locked"))
      in
      expect_ok (Mobile.open_graph host (open_payload dir false));
      let opened = expect_opened !(host.current) in
      check_eq opened.graph_id "graph";
      check_eq (Sync.applied_server_t opened.state) 7;
      check_eq (Runtime.state opened.read_runtime).server_t 7;
      check (Runtime.pending_operations opened.read_runtime <> []);
      check (Sys.file_exists (Filename.concat dir "search/db.sqlite"));
      check_eq !calls 0)

let failed_reopen_keeps_the_previous_runtime () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = Mobile.create (crypto (fun _ -> Error "locked")) in
      expect_ok (Mobile.open_graph host (open_payload dir false));
      let opened = expect_opened !(host.current) in
      check_eq
        (Mobile.open_graph host (open_payload dir true))
        (Error "locked");
      check (expect_opened !(host.current) == opened);
      check (error (Mobile.open_graph host "{"));
      check (expect_opened !(host.current) == opened))

let restoring_a_broken_database_fails_before_key_access () =
  with_directory (fun dir ->
      let calls = ref 0 in
      let host =
        Mobile.create
          (crypto (fun _ ->
               incr calls;
               Error "locked"))
      in
      expect_ok
        (Checkpoint.save_checkpoint_atomic
           (Filename.concat dir "checkpoint")
           (Checkpoint.create "graph" "1" 7));
      Sqlite_store.prepare_staging (Filename.concat dir "graph.sqlite");
      check_eq
        (Mobile.open_graph host (open_payload dir true))
        (Error "graph storage has no DataScript root");
      check_eq !calls 0;
      check_eq !(host.current) None)

let encrypted_open_requires_the_selected_key_and_configures_title_encryption
    () =
  with_directory (fun dir ->
      prepare_graph dir;
      let keys = ref [] in
      let host =
        Mobile.create
          {
            require_key =
              (fun graph ->
                keys := graph :: !keys;
                Ok ());
            encrypt_title =
              (fun graph title -> Ok (graph ^ ":" ^ title));
            decrypt_title = (fun _ title -> Ok title);
          }
      in
      expect_ok (Mobile.open_graph host (open_payload dir true));
      check_eq !keys [ "graph" ];
      let opened = expect_opened !(host.current) in
      check opened.e2ee;
      check_eq
        (opened.read_runtime.encrypt_title "private")
        (Ok "graph:private"))

let reset_and_invalid_events_do_not_require_an_open_graph () =
  let host = host () in
  check_eq
    (Mobile.apply_sync_event host (change_event 7 8))
    (Error "graph runtime is not open");
  check_error
    (Mobile.apply_sync_event host (event_payload "reset" (Value.Map [])));
  check_error (Mobile.apply_sync_event host "null")

let sync_events_persist_cursor_and_rebase_the_read_runtime () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = host () in
      expect_ok (Mobile.open_graph host (open_payload dir false));
      expect_ok (Mobile.apply_sync_event host (change_event 7 8));
      let opened = expect_opened !(host.current) in
      check_eq (Sync.applied_server_t opened.state) 8;
      check_eq (Runtime.state opened.read_runtime).server_t 8;
      check_eq
        (Checkpoint.load_checkpoint opened.checkpoint_path)
        (Ok (Some (Checkpoint.create "graph" "1" 8)));
      expect_ok (Mobile.apply_sync_event host (change_event 6 9));
      check_eq (Sync.applied_server_t opened.state) 9;
      check_eq (Runtime.state opened.read_runtime).server_t 9)

let snapshot_import_activates_a_real_snapshot_and_reopens_it () =
  with_directory (fun dir ->
      let payload = snapshot_request dir false (database ()) in
      let host = host () in
      expect_ok (Mobile.import_snapshot host payload);
      check_eq
        (Sync.applied_server_t (expect_opened !(host.current)).state)
        12;
      ignore
        (expect_ok
           (Store.restore_db (Filename.concat dir "graph.sqlite")));
      let opened = expect_opened !(host.current) in
      check (error (Mobile.import_snapshot host "{}"));
      check (expect_opened !(host.current) == opened))

let encrypted_import_decrypts_before_opening_the_local_graph () =
  with_directory (fun dir ->
      let encrypted =
        Ds.db_with
          [
            Ds.Add
              (Ds.Entity_id 1, "block/title", Ds.String "cipher:Private");
          ]
          (database ())
      in
      let decryptions = ref [] in
      let host =
        Mobile.create
          {
            require_key = (fun _ -> Ok ());
            encrypt_title =
              (fun _ title -> Ok ("cipher:" ^ title));
            decrypt_title =
              (fun graph title ->
                decryptions := graph :: !decryptions;
                if String.starts_with ~prefix:"cipher:" title then
                  Ok (String.sub title 7 (String.length title - 7))
                else Error "invalid ciphertext");
          }
      in
      expect_ok
        (Mobile.import_snapshot host (snapshot_request dir true encrypted));
      check_eq !decryptions [ "graph" ];
      let db =
        expect_ok (Store.restore_db (Filename.concat dir "graph.sqlite"))
      in
      check_eq
        (List.map
           (fun (datom : Ds.datom) -> datom.v)
           (List.of_seq
              (Ds.Db.datoms db Ds.Eavt ~e:1 ~a:"block/title" ())))
        [ Ds.String "Private" ];
      check (expect_opened !(host.current)).e2ee)

let invalid_snapshot_does_not_replace_the_open_runtime_or_checkpoint () =
  with_directory (fun dir ->
      prepare_graph dir;
      let host = host () in
      let download = Filename.concat dir "invalid-snapshot" in
      let channel = open_out_bin download in
      let metadata =
        "{\"ok\":true,\"url\":\"snapshot\",\"t\":12,\"schema-version\":\"1\",\"row-count\":5}"
      in
      let payload =
        json_object
          (open_fields dir false
          @ [
              ("metadataBody", `String metadata);
              ("downloadPath", `String download);
            ])
      in
      Fun.protect
        ~finally:(fun () -> close_out channel)
        (fun () -> output_string channel "broken");
      expect_ok (Mobile.open_graph host (open_payload dir false));
      let opened = expect_opened !(host.current) in
      check (error (Mobile.import_snapshot host payload));
      check (expect_opened !(host.current) == opened);
      check_eq
        (Checkpoint.load_checkpoint opened.checkpoint_path)
        (Ok (Some (Checkpoint.create "graph" "1" 7)));
      ignore
        (expect_ok (Store.restore_db (Filename.concat dir "graph.sqlite"))
         : Ds.db))

let cases =
  [
    case "asset path resolution follows the current graph"
      asset_path_resolution_follows_the_current_graph;
    case "unopened host preserves query and command defaults"
      unopened_host_preserves_query_and_command_defaults;
    case "unopened graph models are isolated and do not open projections"
      unopened_graph_models_are_isolated_and_do_not_open_projections;
    case "graph projection migrates storage but keeps catalog metadata"
      graph_projection_migrates_storage_but_keeps_catalog_metadata;
    case "existing projection is reused without reimporting catalog"
      existing_projection_is_reused_without_reimporting_catalog;
    case "failed catalog open leaves no closed session installed"
      failed_catalog_open_leaves_no_closed_session_installed;
    case "catalog reopen closes connections and clears the open graph"
      catalog_reopen_closes_connections_and_clears_the_open_graph;
    case "opened host reads live runtime and observes close"
      opened_host_reads_live_runtime_and_observes_close;
    case "open validates checkpoint before accessing keys"
      open_validates_checkpoint_before_accessing_keys;
    case
      "plaintext open restores cursor search and today without key access"
      plaintext_open_restores_cursor_search_and_today_without_key_access;
    case "failed reopen keeps the previous runtime"
      failed_reopen_keeps_the_previous_runtime;
    case "restoring a broken database fails before key access"
      restoring_a_broken_database_fails_before_key_access;
    case
      "encrypted open requires the selected key and configures title encryption"
      encrypted_open_requires_the_selected_key_and_configures_title_encryption;
    case "reset and invalid events do not require an open graph"
      reset_and_invalid_events_do_not_require_an_open_graph;
    case "sync events persist cursor and rebase the read runtime"
      sync_events_persist_cursor_and_rebase_the_read_runtime;
    case "snapshot import activates a real snapshot and reopens it"
      snapshot_import_activates_a_real_snapshot_and_reopens_it;
    case "encrypted import decrypts before opening the local graph"
      encrypted_import_decrypts_before_opening_the_local_graph;
    case
      "invalid snapshot does not replace the open runtime or checkpoint"
      invalid_snapshot_does_not_replace_the_open_runtime_or_checkpoint;
  ]
