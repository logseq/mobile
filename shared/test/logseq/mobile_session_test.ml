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

let cases =
  [ case "synced encrypted assets decrypt to raw image bytes" synced_encrypted_assets_decrypt_to_raw_image_bytes;
    case "requests without a database path use the existing session"
      requests_without_a_database_path_use_the_existing_session;
    case "opening a catalog replaces the session and returns its snapshot"
      opening_a_catalog_replaces_the_session_and_returns_its_snapshot;
    case "reopening closes the old catalog and retains persisted catalog data"
      reopening_closes_the_old_catalog_and_retains_persisted_catalog_data;
    case "database open failure propagates without replacing the rpc session"
      database_open_failure_propagates_without_replacing_the_rpc_session;
  ]
