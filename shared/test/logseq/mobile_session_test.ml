open Test_util

let snapshot = "{\"apiVersion\":1,\"method\":\"snapshot\",\"params\":{}}"

let catalog =
  "{\"graphs\":[{\"graph-id\":\"plain\",\"graph-name\":\"Plain\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true}]}"

let host () =
  Mobile_session.create (fun _ -> failwith "unexpected crypto call")

let rec remove_tree path =
  if Sys.file_exists path then begin
    if Sys.is_directory path then begin
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      Unix.rmdir path
    end
    else Sys.remove path
  end

let with_host f =
  let path = Filename.temp_file "logseq-mobile-session" "" in
  let host = host () in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect
    ~finally:(fun () ->
       Mobile_database.close host.Mobile_session.database;
       remove_tree path)
    (fun () -> f host path)

let open_request path =
  "{\"apiVersion\":1,\"method\":\"open\",\"params\":{\"path\":"
  ^ Yojson.Basic.to_string (`String path)
  ^ "}}"

let requests_without_a_database_path_use_the_existing_session () =
  let host = host () in
  let previous = !(host.Mobile_session.session) in
  List.iter
    (fun request ->
       check_eq
         (Rpc_session.call previous request)
         (Mobile_session.call host request);
       check (previous == !(host.Mobile_session.session)))
    [
      snapshot;
      "{";
      "null";
      "{\"apiVersion\":2,\"method\":\"snapshot\",\"params\":{}}";
      "{\"apiVersion\":1,\"method\":\"open\",\"params\":{}}";
      "{\"apiVersion\":1,\"method\":\"open\",\"params\":{\"path\":42}}";
    ]

let opening_a_catalog_replaces_the_session_and_returns_its_snapshot () =
  with_host (fun host dir ->
       let path = Filename.concat dir "catalog.sqlite" in
       let saved = Sqlite.open_session path in
       let previous = !(host.Mobile_session.session) in
       Fun.protect
         ~finally:(fun () -> Sqlite.close saved)
         (fun () ->
            Sqlite.store_string saved "logseq/graph-catalog/v1" catalog);
       Cache_model.cache_local_message
         (Rpc_session.state previous).Session_types.model "draft"
         "Old session" 100;
       let response = Mobile_session.call host (open_request path) in
       let current = !(host.Mobile_session.session) in
       check (not (previous == current));
       check_eq (Rpc_session.call current snapshot) response;
       check_eq (`Bool true)
         (Yojson.Basic.Util.member "ok" (Yojson.Basic.from_string response));
       check_eq [ "plain" ]
         (List.map
            (fun (graph : Api.api_graph) -> graph.Api.id)
            (Rpc_session.state current).Session_types.available_graphs);
       check
         (Cache_model.read_block
            (Rpc_session.state current).Session_types.model "draft"
         = None))

let reopening_closes_the_old_catalog_and_retains_persisted_catalog_data () =
  with_host (fun host dir ->
       let path = Filename.concat dir "catalog.sqlite" in
       ignore (Mobile_session.call host (open_request path));
       match !(host.Mobile_session.database.Mobile_database.catalog) with
       | Some first ->
         Sqlite.store_string first "logseq/graph-catalog/v1" catalog;
         ignore (Mobile_session.call host (open_request path));
         check !(first.Sqlite.closed);
         check_eq [ "plain" ]
           (List.map
              (fun (graph : Api.api_graph) -> graph.Api.id)
              (Rpc_session.state !(host.Mobile_session.session))
              .Session_types.available_graphs)
       | None -> fail "catalog was not opened")

let database_open_failure_propagates_without_replacing_the_rpc_session () =
  with_host (fun host dir ->
       ignore (Mobile_session.call host (open_request (Filename.concat dir "catalog.sqlite")));
       let previous = !(host.Mobile_session.session) in
       check
         (try
             ignore
               (Mobile_session.call host
                  (open_request (Filename.concat dir "missing/catalog.sqlite")));
             false
           with Failure _ -> true);
       check (previous == !(host.Mobile_session.session));
       check
         (!(host.Mobile_session.database.Mobile_database.catalog) = None))

let synced_encrypted_assets_decrypt_to_raw_image_bytes () =
  with_host (fun host directory ->
    let bytes = "\137PNG\000\255image" in
    let ring = { host.Mobile_session.keyring with
      crypto = { host.keyring.crypto with decrypt_aes_gcm = (fun _ _ _ -> Ok bytes) } } in
    Hashtbl.replace ring.keys "encrypted-image" "test-key";
    let options = Mobile_session.host_options host.database ring None in
    let session = Rpc_session.create_session { options with
      load_graph_catalog = Some (fun () -> Some {|{"graphs":[{"graph-id":"encrypted-image","graph-e2ee?":true,"graph-ready-for-use?":true}]}|});
      resolve_asset_path = (fun path -> Filename.concat directory path) } in
    let call action payload = Rpc_session.call session (Yojson.Basic.to_string (`Assoc [
      "apiVersion", `Int 1; "method", `String "dispatch";
      "params", `Assoc ["action", `String action; "payload", `String payload]])) |> Yojson.Basic.from_string in
    ignore (call "configure" {|{"graphId":"encrypted-image","baseUrl":"https://api.example","token":"test"}|});
    let source = Filename.concat directory "download" in
    ignore (Asset_files.write_file source (Transit_native.Transit.Json.to_string
      (Transit_core.Json.Array [Binary "iv"; Binary "ciphertext"])));
    let result = call "cacheDownloadedAsset" (Yojson.Basic.to_string (`Assoc [
      "graphId", `String "encrypted-image"; "uuid", `String "image";
      "assetType", `String "png"; "path", `String source])) in
    let open Yojson.Basic.Util in
    check_eq ~msg:"encrypted image download succeeds" (result |> member "ok") (`Bool true);
    let path = result |> member "result" |> member "localPath" |> to_string in
    check_eq (Asset_files.read_file path) (Ok bytes))

let configured_identity_authors_new_nodes_and_survives_reopen () =
  with_host (fun host directory ->
    let module Ds = Datascript in
    let module Graph = Mobile_graph in
    let module Ops = Pending_ops in
    let graph = host.Mobile_session.database.Mobile_database.graph in
    let active = Filename.concat directory "graph.sqlite" in
    let checkpoint = Filename.concat directory "checkpoint" in
    Graph_sqlite.prepare_staging active;
    ignore (Ds.store (Graph_bootstrap.install_canonical_entities
      (Ds.parse_tx_data_string Graph_bootstrap_data.transaction_edn
       |> List.map Graph_bootstrap.normalize_scalar_maps) (Graph_store.storage active)));
    (match Sync_checkpoint.save_checkpoint_atomic checkpoint (Sync_checkpoint.create "graph" "1" 7) with
     | Ok () -> () | Error message -> fail message);
    let configure token =
      let payload = Yojson.Basic.to_string (`Assoc ["graphId", `String "graph";
        "baseUrl", `String "https://example.com"; "token", `String token]) in
      let request = Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
        "params", `Assoc ["action", `String "configure"; "payload", `String payload]]) in
      let response = Mobile_session.call host request |> Yojson.Basic.from_string in
      check_eq ~msg:"configure succeeds" (Yojson.Basic.Util.member "ok" response) (`Bool true)
    in
    let open_graph () =
      match Graph.open_graph graph (Yojson.Basic.to_string (`Assoc ["graphId", `String "graph";
        "activePath", `String active; "checkpointPath", `String checkpoint; "isEncrypted", `Bool false])) with
      | Ok () -> () | Error message -> fail message
    in
    let database () = match !(graph.current) with
      | Some opened -> Graph_runtime.db opened.read_runtime
      | None -> fail "graph is not open" in
    let author uuid =
      let db = database () in
      match Ds.entity db (Ds.Lookup_ref ("block/uuid", Ds.Uuid uuid)) with
      | None -> None
      | Some entity ->
        match Ds.Entity.entity_attr_raw entity "logseq.property/created-by-ref" with
        | Some (Ds.One_value (Ds.Ref id)) ->
          Option.bind (Ds.entity db (Ds.Entity_id id)) (fun actor ->
            match Ds.Entity.entity_attr_raw actor "block/uuid" with
            | Some (Ds.One_value (Ds.Uuid uuid)) -> Some uuid | _ -> None)
        | _ -> None in
    let stage id intent =
      match Graph.stage graph { Ops.operation_id = id; base_t = 7; state = Ops.Queued; intent } with
      | Ok _ -> () | Error message -> fail message in
    let alice = "00000000-0000-4000-8000-000000000001" in
    let bob = "00000000-0000-4000-8000-000000000002" in
    configure "header.eyJzdWIiOiAiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDAxIiwgImNvZ25pdG86dXNlcm5hbWUiOiAiQWxpY2UiLCAiZW1haWwiOiAiYWxpY2VAZXhhbXBsZS5jb20ifQ.signature";
    open_graph ();
    let journals = Graph_runtime.blocks (Option.get !(graph.current)).read_runtime in
    List.iter (fun (block : Cache_model.block) ->
      check_eq ~msg:"automatic journal nodes retain the signed-in creator" (author block.uuid) (Some alice)) journals;
    stage "page-create" (Ops.Create_page { uuid = "page"; title = "Project"; created_at = 10 });
    check_eq ~msg:"new pages carry a creator entity reference" (author "page") (Some alice);
    stage "block-create" (Ops.Insert_block { uuid = "first"; title = "First";
      page_uuid = "page"; parent_uuid = "page"; order = "a0"; created_at = 11 });
    stage "blank-create" (Ops.Insert_block { uuid = "blank"; title = "";
      page_uuid = "page"; parent_uuid = "page"; order = "a1"; created_at = 12 });
    check_eq (author "first") (Some alice);
    configure "header.eyJzdWIiOiAiMDAwMDAwMDAtMDAwMC00MDAwLTgwMDAtMDAwMDAwMDAwMDAyIiwgImNvZ25pdG86dXNlcm5hbWUiOiAiQm9iIiwgImVtYWlsIjogImJvYkBleGFtcGxlLmNvbSJ9.signature";
    stage "ordinary-edit" (Ops.Save_title { uuid = "first"; expected_title = "First"; title = "Edited" });
    check_eq ~msg:"editing another user's nonempty block preserves its creator" (author "first") (Some alice);
    stage "fill-blank" (Ops.Save_title { uuid = "blank"; expected_title = ""; title = "Bob's text" });
    check_eq ~msg:"first text entry assigns the current creator, matching Logseq" (author "blank") (Some bob);
    stage "second-create" (Ops.Insert_block { uuid = "second"; title = "Second";
      page_uuid = "page"; parent_uuid = "page"; order = "a2"; created_at = 13 });
    check_eq (author "second") (Some bob);
    open_graph ();
    check_eq ~msg:"offline pending replay preserves the original account" (author "first") (Some alice);
    check_eq (author "second") (Some bob);
    let db = database () in
    let actor = Option.get (Ds.entity db (Ds.Lookup_ref ("block/uuid", Ds.Uuid alice))) in
    check_eq (Ds.Entity.entity_attr_raw actor "logseq.property.user/email")
      (Some (Ds.One_value (Ds.String "alice@example.com")));
    configure "malformed-token";
    stage "without-identity" (Ops.Insert_block { uuid = "anonymous"; title = "Anonymous";
      page_uuid = "page"; parent_uuid = "page"; order = "a3"; created_at = 14 });
    check_eq ~msg:"invalid or removed identity never reuses a prior account" (author "anonymous") None)

let assets_are_stored_inside_the_open_graph () =
  with_host (fun host root ->
    let directory = Filename.concat root "graphs" in
    Unix.mkdir directory 0o700;
    let directory = Filename.concat directory "My Notes - graph" in
    Unix.mkdir directory 0o700;
    let active = Filename.concat directory "graph.sqlite" in
    let checkpoint = Filename.concat directory "sync.checkpoint" in
    Graph_sqlite.prepare_staging active;
    ignore (Datascript.store (Graph_bootstrap.install_canonical_entities
      (Datascript.parse_tx_data_string Graph_bootstrap_data.transaction_edn
       |> List.map Graph_bootstrap.normalize_scalar_maps) (Graph_store.storage active)));
    (match Sync_checkpoint.save_checkpoint_atomic checkpoint (Sync_checkpoint.create "graph" "1" 7) with
     | Ok () -> () | Error message -> fail message);
    let call action fields = Mobile_session.call host (Yojson.Basic.to_string (`Assoc [
      "apiVersion", `Int 1; "method", `String "dispatch";
      "params", `Assoc ["action", `String action;
        "payload", `String (Yojson.Basic.to_string (`Assoc fields))]])) |> Yojson.Basic.from_string in
    let ok result = check_eq ~msg:"RPC succeeds" (Yojson.Basic.Util.member "ok" result) (`Bool true) in
    ok (call "configure" ["graphId", `String "graph"; "baseUrl", `String "https://example.com"; "token", `String "test"]);
    ok (call "openGraph" ["graphId", `String "graph"; "activePath", `String active;
      "checkpointPath", `String checkpoint; "isEncrypted", `Bool false]);
    let source = Filename.concat root "photo.png" in
    ignore (Asset_files.write_file source "local-image");
    ok (call "addAsset" ["uuid", `String "local-photo"; "title", `String "Photo";
      "assetType", `String "png"; "assetSize", `Int 11; "assetChecksum", `String "checksum";
      "localPath", `String source]);
    check_eq ~msg:"imported files belong to the graph"
      (Asset_files.read_file (Filename.concat directory "Assets/local-photo-photo.png")) (Ok "local-image");
    let second_source_dir = Filename.concat root "second" in
    Unix.mkdir second_source_dir 0o700;
    let second_source = Filename.concat second_source_dir "photo.png" in
    ignore (Asset_files.write_file second_source "second-image");
    ok (call "addAsset" ["uuid", `String "second-photo"; "title", `String "Photo";
      "assetType", `String "png"; "assetSize", `Int 12; "assetChecksum", `String "checksum2";
      "localPath", `String second_source]);
    check_eq (Asset_files.read_file (Filename.concat directory "Assets/second-photo-photo.png")) (Ok "second-image");
    check_eq ~msg:"same filenames never overwrite an existing attachment"
      (Asset_files.read_file (Filename.concat directory "Assets/local-photo-photo.png")) (Ok "local-image");
    let missing = call "addAsset" ["uuid", `String "missing"; "title", `String "Missing";
      "assetType", `String "png"; "assetSize", `Int 0; "assetChecksum", `String "checksum";
      "localPath", `String (Filename.concat root "missing.png")] in
    check_eq ~msg:"missing files are rejected before staging" (Yojson.Basic.Util.member "ok" missing) (`Bool false);
    let prepare uuid = call "prepareAssetDownload" ["uuid", `String uuid; "assetType", `String "png"] in
    let pending = prepare "remote-photo" in
    ok pending;
    check (Yojson.Basic.Util.member "request" (Yojson.Basic.Util.member "result" pending) <> `Null);
    ok (call "cacheDownloadedAsset" ["uuid", `String "remote-photo"; "assetType", `String "png"; "path", `String source]);
    let cached = prepare "remote-photo" in
    ok cached;
    check_eq ~msg:"remote cache belongs to the graph"
      (cached |> Yojson.Basic.Util.member "result" |> Yojson.Basic.Util.member "localPath")
      (`String (Filename.concat directory "Assets/remote-photo.png"));
    check_eq (Asset_files.read_file (Filename.concat directory "Assets/remote-photo.png")) (Ok "local-image");
    let legacy = Filename.concat root "Assets" in
    Unix.mkdir legacy 0o700;
    ignore (Asset_files.write_file (Filename.concat legacy "legacy.png") "old-image");
    let graph = host.Mobile_session.database.Mobile_database.graph in
    check_eq ~msg:"old upload references migrate to this graph"
      (Mobile_graph.resolve_asset_path graph "Assets/legacy.png")
      (Filename.concat directory "Assets/legacy.png");
    check_eq (Asset_files.read_file (Filename.concat directory "Assets/legacy.png")) (Ok "old-image");
    let legacy_graph = Filename.concat legacy "graph" in
    Unix.mkdir legacy_graph 0o700;
    ignore (Asset_files.write_file (Filename.concat legacy_graph "old-cache.png") "cached-image");
    let cached = prepare "old-cache" in
    ok cached;
    check_eq (cached |> Yojson.Basic.Util.member "result" |> Yojson.Basic.Util.member "localPath")
      (`String (Filename.concat directory "Assets/old-cache.png"));
    check_eq (Asset_files.read_file (Filename.concat directory "Assets/old-cache.png")) (Ok "cached-image");
    let neighbor = Filename.concat root "graphs/Other - other" in
    Unix.mkdir neighbor 0o700;
    check_eq ~msg:"another graph cannot read a cached attachment"
      (Asset_files.resolve_path (Some (Filename.concat neighbor "sync.checkpoint")) "Assets/remote-photo.png")
      (Filename.concat neighbor "Assets/remote-photo.png"))

let cases =
  [ case "assets are stored inside the open graph" assets_are_stored_inside_the_open_graph; case "configured identity authors new nodes and survives reopen" configured_identity_authors_new_nodes_and_survives_reopen;
    case "synced encrypted assets decrypt to raw image bytes" synced_encrypted_assets_decrypt_to_raw_image_bytes;
    case "requests without a database path use the existing session"
      requests_without_a_database_path_use_the_existing_session;
    case "opening a catalog replaces the session and returns its snapshot"
      opening_a_catalog_replaces_the_session_and_returns_its_snapshot;
    case "reopening closes the old catalog and retains persisted catalog data"
      reopening_closes_the_old_catalog_and_retains_persisted_catalog_data;
    case "database open failure propagates without replacing the rpc session"
      database_open_failure_propagates_without_replacing_the_rpc_session;
  ]
