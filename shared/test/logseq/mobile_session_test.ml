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

let with_favorite_graphs f =
  with_host (fun host dir ->
    let catalog_path = Filename.concat dir "catalog.sqlite" in
    let saved = Sqlite.open_session catalog_path in
    Sqlite.store_string saved "logseq/graph-catalog/v1"
      {|{"graphs":[{"graph-id":"graph-a","graph-name":"A","graph-e2ee?":false,"graph-ready-for-use?":true},{"graph-id":"graph-b","graph-name":"B","graph-e2ee?":false,"graph-ready-for-use?":true}]}|};
    Sqlite.close saved;
    ignore (Mobile_session.call host (open_request catalog_path));
    let call action fields =
      let request = Yojson.Basic.to_string (`Assoc ["apiVersion", `Int 1; "method", `String "dispatch";
        "params", `Assoc ["action", `String action; "payload", `String (Yojson.Basic.to_string (`Assoc fields))]]) in
      let response = Mobile_session.call host request |> Yojson.Basic.from_string in
      check_eq ~msg:(action ^ " succeeds") (Yojson.Basic.Util.member "ok" response) (`Bool true);
      Yojson.Basic.Util.member "result" response in
    ignore (call "configure" ["baseUrl", `String "https://example.com"; "token", `String ""; "graphId", `String "graph-a"]);
    let fields id = ["graphId", `String id;
      "activePath", `String (Filename.concat dir (id ^ ".sqlite"));
      "checkpointPath", `String (Filename.concat dir (id ^ ".checkpoint"))] in
    let database id storage =
      let module Ds = Datascript in
      Ds.db_with [
        Ds.Add (Ds.Entity_id 1, "block/uuid", Ds.Uuid (id ^ "-favorites"));
        Ds.Add (Ds.Entity_id 1, "block/name", Ds.String "$$$favorites");
        Ds.Add (Ds.Entity_id 2, "block/uuid", Ds.Uuid (id ^ "-page"));
        Ds.Add (Ds.Entity_id 2, "block/name", Ds.String id);
        Ds.Add (Ds.Entity_id 2, "block/title", Ds.String ("Favorite " ^ id));
        Ds.Add (Ds.Entity_id 3, "block/uuid", Ds.Uuid (id ^ "-link"));
        Ds.Add (Ds.Entity_id 3, "block/page", Ds.Ref 1);
        Ds.Add (Ds.Entity_id 3, "block/parent", Ds.Ref 1);
        Ds.Add (Ds.Entity_id 3, "block/link", Ds.Ref 2);
        Ds.Add (Ds.Entity_id 3, "block/order", Ds.String "a0")
      ] (Ds.empty_db ~schema:Graph_bootstrap.native_schema ~storage ()) in
    let cache id =
      let path = Filename.concat dir (id ^ ".sqlite") in
      Graph_sqlite.prepare_staging path;
      ignore (Datascript.store (database id (Graph_store.storage path)));
      match Sync_checkpoint.save_checkpoint_atomic (Filename.concat dir (id ^ ".checkpoint"))
        (Sync_checkpoint.create id "1" 12) with Ok () -> () | Error message -> fail message in
    let download id =
      let rows = Mobile_graph_test.expect_ok (Graph_bootstrap.snapshot_rows
        (database id (Datascript.memory_storage ()))) in
      let path = Filename.concat dir (id ^ ".snapshot") in
      let output = open_out_bin path in
      Fun.protect ~finally:(fun () -> close_out output)
        (fun () -> output_string output (Graph_bootstrap.frame_rows rows));
      ["downloadPath", `String path; "metadataBody", `String (Yojson.Basic.to_string (`Assoc [
        "ok", `Bool true; "url", `String "snapshot"; "t", `Int 12;
        "schema-version", `String "1"; "row-count", `Int (List.length rows)]))] in
    f host call fields cache download)

let favorite_ids response =
  let open Yojson.Basic.Util in
  response |> member "favorites" |> to_list |> List.map (fun page -> page |> member "uuid" |> to_string)

let first_cached_graph_bootstrap_loads_favorites () =
  with_favorite_graphs (fun _ call fields cache _ ->
    cache "graph-a";
    let first = call "bootstrapGraph" (fields "graph-a") in
    check_eq (Yojson.Basic.Util.member "kind" (Yojson.Basic.Util.member "graphBootstrap" first)) (`String "ready");
    check_eq ~msg:"the first cached graph response contains favorites"
      (favorite_ids first) ["graph-a-page"];
    check_eq ~msg:"reusing the active graph retains favorites"
      (favorite_ids (call "bootstrapGraph" (fields "graph-a"))) ["graph-a-page"])

let first_download_import_loads_favorites () =
  with_favorite_graphs (fun _ call fields _ download ->
    let plan = call "bootstrapGraph" (fields "graph-a") in
    check_eq (Yojson.Basic.Util.member "kind" (Yojson.Basic.Util.member "graphBootstrap" plan)) (`String "download");
    check_eq ~msg:"a pending download has no stale favorites" (favorite_ids plan) [];
    let imported = call "importSnapshot" (fields "graph-a" @ download "graph-a") in
    check_eq ~msg:"the first imported graph response contains favorites"
      (favorite_ids imported) ["graph-a-page"])

let cold_launch_defers_sidebar_but_switching_graphs_loads_it () =
  with_favorite_graphs (fun host call fields cache _ ->
    cache "graph-a"; cache "graph-b";
    check_eq ~msg:"cold launch keeps sidebar reads off the critical path"
      (favorite_ids (call "openGraph" (fields "graph-a"))) [];
    let session = !(host.Mobile_session.session) in
    ignore (Rpc_test.dispatch_json session "selectGraph" "graph-b");
    check_eq ~msg:"switching away from a deferred launch loads the new graph favorites"
      (favorite_ids (call "bootstrapGraph" (fields "graph-b"))) ["graph-b-page"];
    ignore (Rpc_test.dispatch_json session "selectGraph" "graph-a");
    check_eq ~msg:"switching back replaces favorites with the selected graph"
      (favorite_ids (call "bootstrapGraph" (fields "graph-a"))) ["graph-a-page"])

let collapsed_nodes_survive_navigation_restart_and_graph_switches () =
  with_host (fun host dir ->
    let path = Filename.concat dir "catalog.sqlite" in
    let parent = Rpc_test.synced_block "parent" "Parent" in
    let child = { parent with Cache_model.uuid = "child"; title = "Child";
      parent_id = Some "parent" } in
    let reopen () =
      ignore (Mobile_session.call host (open_request path));
      let catalog = Option.get !(host.Mobile_session.database.Mobile_database.catalog) in
      let options = Mobile_session.host_options host.database host.keyring (Some catalog) in
      Rpc_session.create_session { options with
        graph_blocks = Some (fun () -> Some [parent; child]);
        graph_page_blocks = Some (fun _ -> Some [parent; child]);
        graph_node_destination = Some (fun uuid ->
          Some ({ Cache_model.uuid = uuid; title = "Page" }, false)) }
    in
    let configure session graph =
      Rpc_test.dispatch_json session "configure"
        (Yojson.Basic.to_string (`Assoc ["baseUrl", `String "https://example.com";
          "graphId", `String graph; "token", `String "test"]))
      |> Rpc_test.response_result in
    let collapsed result =
      Rpc_test.member "collapsedBlockIds" (Rpc_test.member "outlinerState" result) in
    let expect result uuids =
      check_eq ~msg:"the graph remembers the user's collapsed nodes" (collapsed result)
        (`List (List.map (fun uuid -> `String uuid) uuids));
      let row_ids = Rpc_test.json_items "outlinerRows" result
        |> List.map (fun row -> Rpc_test.member "uuid" (Rpc_test.member "block" row)) in
      check_eq ~msg:"restored folding controls the visible journal rows" row_ids
        (if uuids = [] then [`String "parent"; `String "child"] else [`String "parent"]) in
    let session = reopen () in
    expect (configure session "graph-a") [];
    ignore (Rpc_test.outliner_block_event session "toggleCollapsed" "parent");
    let opened = Rpc_test.response_result (Rpc_test.dispatch_json session "openNode" {|{"uuid":"page"}|}) in
    expect opened ["parent"];
    check_eq ~msg:"opening the journal page keeps folded children hidden"
      (Rpc_test.node_row_ids opened) ["parent"];
    ignore (Rpc_test.outliner_block_event session "toggleCollapsed" "parent");
    expect (Rpc_test.response_result (Rpc_test.dispatch_json session "closeNode" "")) [];
    ignore (Rpc_test.outliner_block_event session "toggleCollapsed" "parent");
    expect (Rpc_test.response_result (Rpc_test.dispatch_json session "clearSelectedPage" "")) ["parent"];
    let session = reopen () in
    expect (configure session "graph-a") ["parent"];
    expect (configure session "graph-b") [];
    expect (configure session "graph-a") ["parent"];
    ignore (Rpc_test.outliner_block_event session "toggleCollapsed" "parent");
    let session = reopen () in
    expect (configure session "graph-a") [])

let server_rejections_survive_restart_and_remain_scoped_to_the_graph () =
  with_favorite_graphs (fun host call fields cache _ ->
    let module J = Yojson.Basic in
    let module U = Yojson.Basic.Util in
    cache "graph-a"; cache "graph-b";
    ignore (call "configure" ["baseUrl", `String "https://example.com"; "token", `String "access"; "graphId", `String "graph-a"]);
    ignore (call "bootstrapGraph" (fields "graph-a"));
    let graph = host.Mobile_session.database.Mobile_database.graph in
    let operation = { Pending_ops.operation_id = "rejected-create"; base_t = 12; state = Pending_ops.Queued;
      intent = Pending_ops.Create_page { uuid = "00000000-0000-4000-8000-000000000020";
        title = "Created page"; created_at = 7 } } in
    (match Mobile_graph.stage graph operation with Ok () -> () | Error message -> fail message);
    let dispatch action payload = Rpc_test.dispatch_json !(host.Mobile_session.session) action payload |> Rpc_test.response_result in
    let request () = Rpc_test.required_pending (dispatch "beginPendingSync" "") in
    let first = request () in
    let failed = Rpc_test.pending_completion !(host.Mobile_session.session) first (`Int 403)
      (`String {|{"error":"permission denied 中文 😀"}|}) `Null in
    check ~msg:"the original rejection is returned" (U.member "pendingSyncError" failed <> `Null);
    let directory = Filename.dirname (List.assoc "activePath" (fields "graph-a") |> U.to_string) in
    let reopen id =
      ignore (Mobile_session.call host (open_request (Filename.concat directory "catalog.sqlite")));
      ignore (call "configure" ["baseUrl", `String "https://example.com"; "token", `String "access"; "graphId", `String id]);
      call "bootstrapGraph" (fields id) in
    let restored = reopen "graph-a" in
    check ~msg:"reopening cannot erase a pending server rejection"
      (match U.member "pendingSyncError" restored with `String message -> String.length message > 0 | _ -> false);
    check_eq ~msg:"another graph never inherits the previous graph's error"
      (U.member "pendingSyncError" (reopen "graph-b")) `Null;
    let restored = reopen "graph-a" in
    check ~msg:"returning to the failed graph restores its rejection" (U.member "pendingSyncError" restored <> `Null);
    let retry = request () in
    let tx = U.member "bodyObject" retry |> U.member "txs" |> U.to_list |> List.hd in
    let body = J.to_string (`Assoc ["type", `String "tx/batch/ok"; "t-before", `Int 12; "t", `Int 13;
      "txs", `List [`Assoc ["t", `Int 13; "tx-id", U.member "tx-id" tx; "tx", U.member "tx" tx]]]) in
    let accepted = Rpc_test.pending_completion !(host.Mobile_session.session) retry (`Int 200) (`String body) `Null in
    check_eq ~msg:"acceptance resolves that operation's persisted error" (U.member "pendingSyncError" accepted) `Null;
    check_eq ~msg:"resolved rejections stay resolved after restart" (U.member "pendingSyncError" (reopen "graph-a")) `Null)

let sync_errors_follow_their_operations_through_other_acceptances_and_lost_replies () =
  with_favorite_graphs (fun host call fields cache _ ->
    let module J = Yojson.Basic in
    let module U = Yojson.Basic.Util in
    cache "graph-a";
    ignore (call "configure" ["baseUrl", `String "https://example.com"; "token", `String "access"; "graphId", `String "graph-a"]);
    ignore (call "bootstrapGraph" (fields "graph-a"));
    let graph = host.Mobile_session.database.Mobile_database.graph in
    let session = !(host.Mobile_session.session) in
    let request () = Rpc_test.required_pending (Rpc_test.response_result (Rpc_test.dispatch_json session "beginPendingSync" "")) in
    let stage id uuid =
      let operation = { Pending_ops.operation_id = id; base_t = Option.get (Mobile_graph.sync_cursor graph);
        state = Pending_ops.Queued; intent = Pending_ops.Create_page { uuid; title = id; created_at = 7 } } in
      match Mobile_graph.stage graph operation with Ok () -> () | Error message -> fail message in
    let acknowledgement request =
      let tx = U.member "bodyObject" request |> U.member "txs" |> U.to_list |> List.hd in
      let before = Option.get (Mobile_graph.sync_cursor graph) in
      J.to_string (`Assoc ["type", `String "tx/batch/ok"; "graphId", `String "graph-a";
        "t-before", `Int before; "t", `Int (before + 1);
        "txs", `List [`Assoc ["t", `Int (before + 1); "tx-id", U.member "tx-id" tx; "tx", U.member "tx" tx]]]) in
    let has text result = match U.member "pendingSyncError" result with
      | `String message -> (try ignore (Str.search_forward (Str.regexp_string text) message 0); true with Not_found -> false)
      | _ -> false in
    stage "rejected-first" "00000000-0000-4000-8000-000000000030";
    ignore (Rpc_test.pending_completion session (request ()) (`Int 200)
      (`String {|{"type":"tx/reject","reason":"validation failed","error-detail":"First operation remains rejected"}|}) `Null);
    stage "accepted-second" "00000000-0000-4000-8000-000000000031";
    let second = request () in
    let accepted = Rpc_test.pending_completion session second (`Int 200) (`String (acknowledgement second)) `Null in
    check ~msg:"an unrelated success never hides an unresolved rejection" (has "First operation remains rejected" accepted);
    stage "lost-reply" "00000000-0000-4000-8000-000000000032";
    let third = request () in
    let body = acknowledgement third in
    let failed = Rpc_test.pending_completion session third (`Int 503) (`String "Temporary gateway failure") `Null in
    check ~msg:"an interrupted request reports its own failure" (has "Temporary gateway failure" failed);
    let echoed = Rpc_test.dispatch_json session "applySyncEvent" body |> Rpc_test.response_result in
    check ~msg:"a confirmed server echo resolves the lost reply's error" (not (has "Temporary gateway failure" echoed));
    check ~msg:"server confirmation preserves other unresolved failures" (has "First operation remains rejected" echoed);
    let late_failure = Rpc_test.pending_completion session third (`Int 503) (`String "Late failed HTTP reply") `Null in
    check ~msg:"a late HTTP failure cannot recreate an already confirmed operation's error" (not (has "Late failed HTTP reply" late_failure));
    ignore (Rpc_test.pending_completion session third (`Int 200) (`String body) `Null))

let existing_graph_icons_reach_favorites_headers_and_hydrated_nodes () =
  with_favorite_graphs (fun host call fields cache _ ->
    let module Ds = Datascript in
    let module U = Yojson.Basic.Util in
    cache "graph-a";
    let path = List.assoc "activePath" (fields "graph-a") |> U.to_string in
    let db = match Graph_store.restore_db path with Ok db -> db | Error message -> fail message in
    let icon kind id color = Ds.Map [Ds.Keyword "type", Ds.Keyword kind;
      Ds.Keyword "id", Ds.String id; Ds.Keyword "color", Ds.String color] in
    let db = Ds.db_with [
      Ds.Add (Ds.Entity_id 2, "logseq.property/icon", icon "tabler-icon" "Rocket" "#fb434c");
      Ds.Add (Ds.Entity_id 4, "block/uuid", Ds.Uuid "icon-block");
      Ds.Add (Ds.Entity_id 4, "block/title", Ds.String "Colored node");
      Ds.Add (Ds.Entity_id 4, "block/page", Ds.Ref 2);
      Ds.Add (Ds.Entity_id 4, "block/parent", Ds.Ref 2);
      Ds.Add (Ds.Entity_id 4, "block/order", Ds.String "a0");
      Ds.Add (Ds.Entity_id 4, "logseq.property/icon", icon "emoji" "wave" "#00b55b");
      Ds.Add (Ds.Entity_id 4, "block/tags", Ds.Ref 5);
      Ds.Add (Ds.Entity_id 5, "block/uuid", Ds.Uuid "icon-tag");
      Ds.Add (Ds.Entity_id 5, "block/title", Ds.String "Colored tag");
      Ds.Add (Ds.Entity_id 5, "logseq.property/icon", icon "tabler-icon" "HeartFilled" "#5e69d2")
    ] db in
    ignore (Ds.store db);
    let ready = call "bootstrapGraph" (fields "graph-a") in
    let expect result uuid id color =
      let icons = result |> U.member "nodeIcons" in
      check ~msg:"graph metadata includes existing node icons" (icons <> `Null);
      let descriptor = U.member uuid icons in
      check_eq ~msg:(uuid ^ " keeps its existing icon") (U.member "id" descriptor) (`String id);
      check_eq ~msg:(uuid ^ " keeps its existing color") (U.member "color" descriptor) (`String color) in
    expect ready "graph-a-page" "Rocket" "#fb434c";
    let opened = call "openNode" ["uuid", `String "graph-a-page"] in
    expect opened "graph-a-page" "Rocket" "#fb434c";
    expect opened "icon-block" "wave" "#00b55b";
    (* A fresh immutable read verifies the same precedence used on reopening. *)
    let db = Ds.db_with [Ds.Retract (Ds.Entity_id 4, "logseq.property/icon", Some (icon "emoji" "wave" "#00b55b"))] db in
    check_eq ~msg:"the fixture removes only the explicit node icon"
      (Graph_read.value db 4 "logseq.property/icon") None;
    ignore (Ds.store db);
    ignore (Mobile_session.call host (open_request (Filename.concat (Filename.dirname path) "catalog.sqlite")));
    ignore (call "configure" ["graphId", `String "graph-a"; "baseUrl", `String "https://example.com"; "token", `String ""]);
    ignore (call "bootstrapGraph" (fields "graph-a"));
    let inherited = call "openNode" ["uuid", `String "graph-a-page"] in
    expect inherited "icon-block" "HeartFilled" "#5e69d2")

let cases =
  [ case "existing graph icons reach favorites headers and hydrated nodes" existing_graph_icons_reach_favorites_headers_and_hydrated_nodes;
    case "sync errors follow operations through other acceptances and lost replies" sync_errors_follow_their_operations_through_other_acceptances_and_lost_replies;
    case "server rejections survive restart and stay graph scoped" server_rejections_survive_restart_and_remain_scoped_to_the_graph;
    case "collapsed nodes survive navigation restart and graph switches" collapsed_nodes_survive_navigation_restart_and_graph_switches;
    case "first cached graph bootstrap loads favorites" first_cached_graph_bootstrap_loads_favorites;
    case "first download import loads favorites" first_download_import_loads_favorites;
    case "cold launch defers sidebar but switching graphs loads it" cold_launch_defers_sidebar_but_switching_graphs_loads_it; case "assets are stored inside the open graph" assets_are_stored_inside_the_open_graph; case "configured identity authors new nodes and survives reopen" configured_identity_authors_new_nodes_and_survives_reopen;
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
