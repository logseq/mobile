module J = Yojson.Basic
module U = Yojson.Basic.Util
module Live = Live_sync

let crypto_call input =
  let path = Live.env "LOGSEQ_E2E_CRYPTO_HELPER" in
  let output, request, errors = Unix.open_process_full (Filename.quote path) (Unix.environment ()) in
  output_string request (input ^ "\n"); flush request;
  let result = input_line output in
  ignore (Unix.close_process_full (output, request, errors));
  result

let () =
  let encrypted = Sys.getenv_opt "LOGSEQ_E2E_ENCRYPTED" = Some "1" in
  let crypto = Platform_crypto.crypto crypto_call in
  let key = String.make 32 '\000' in
  let encrypt title = if encrypted then E2ee.encrypt_value crypto key (Transit_core.Json.String title) else Ok title in
  let decrypt title = if encrypted then
    Result.bind (E2ee.decrypt_value crypto key title) (function Transit_core.Json.String s -> Ok s | _ -> Error "Expected title")
    else Ok title in
  let token = Live.env "LOGSEQ_LIVE_TOKEN" in
  let base_url = Option.value ~default:"http://127.0.0.1:8787" (Sys.getenv_opt "LOGSEQ_LIVE_BASE_URL") in
  let cfg = Live.create_and_upload (Live.config base_url token "")
      ("mobile-asset-e2e-" ^ string_of_int (Api.epoch_ms ())) encrypted encrypt in
  let metadata, download = Live.download_snapshot cfg in
  Live.with_temp_dir "logseq-mobile-asset-e2e" (fun dir ->
    let active = Live.import_downloaded cfg.graph_id (if encrypted then Some decrypt else None) dir metadata download in
    Live.remove_file download;
    let host = Mobile_session.create crypto_call in
    Fun.protect ~finally:(fun () -> Mobile_database.close host.database) (fun () ->
      let call method_ fields =
        let response = Mobile_session.call host (J.to_string (`Assoc [
          "apiVersion", `Int 1; "method", `String method_; "params", `Assoc fields])) |> J.from_string in
        if U.member "ok" response <> `Bool true then
          failwith (J.to_string (U.member "error" response));
        U.member "result" response in
      let dispatch action fields = call "dispatch" ["action", `String action; "payload", `String (J.to_string (`Assoc fields))] in
      ignore (call "open" ["path", `String (Filename.concat dir "catalog.sqlite")]);
      ignore (dispatch "configure" ["baseUrl", `String base_url; "graphId", `String cfg.graph_id; "token", `String token]);
      ignore (dispatch "refreshGraphCatalog" []);
      if encrypted then ignore (Live.require_ok "load test graph key" (E2ee_keyring.load_cached host.keyring cfg));
      ignore (dispatch "openGraph" ["graphId", `String cfg.graph_id; "activePath", `String active;
        "checkpointPath", `String (Filename.concat dir "sync.checkpoint"); "isEncrypted", `Bool encrypted]);
      let uuid = Graph_runtime.fresh_uuid () in
      let bytes = "\137PNG\000\255mobile image" in
      let asset = Live.write_temp "logseq-mobile-image" bytes in
      Fun.protect ~finally:(fun () -> Live.remove_file asset) (fun () ->
        ignore (dispatch "addAsset" ["uuid", `String uuid; "title", `String "Mobile photo.png";
          "assetType", `String "png"; "assetSize", `Int (String.length bytes);
          "assetChecksum", `String (Digest.to_hex (Digest.string bytes)); "localPath", `String asset;
          "now", `Int (Api.epoch_ms ())]);
        print_endline "PASS: image captured locally before any upload";
        let pull () =
          let since = Option.get (Mobile_graph.sync_cursor host.database.graph) in
          let response = Live.expect "mobile journal pull" [200]
            (Api.request cfg "GET" ("/sync/" ^ cfg.graph_id ^ "/pull?since=" ^ string_of_int since) None) in
          ignore (call "dispatch" ["action", `String "applySyncEvent"; "payload", `String response.body]) in
        for _ = 1 to 8 do
          let rec pump result =
            match U.member "pendingSyncRequest" result with
            | `Null -> ()
            | request ->
              let get name = U.member name request |> U.to_string in
              let api = { Api.method_ = get "method"; url = get "url"; token;
                body = (match U.member "body" request with `String body -> Some body | _ -> None) } in
              let response = match U.member "filePath" request with
                | `String path ->
                  let headers = U.member "headers" request |> U.to_assoc |> List.map (fun (k,v) -> k,U.to_string v) in
                  Live.require_ok "mobile asset upload" (Http.upload_file {Api.request=api; file_path=path; content_type=get "contentType"; headers})
                | _ -> Live.require_ok "mobile datom sync" (Http.send api) in
              Printf.printf "mobile request %s %s status=%d\n%!" api.method_ (List.hd (String.split_on_char '?' api.url)) response.status;
              if response.status >= 300 then failwith ("Upload failed: " ^ response.body);
              let completed = dispatch "completePendingSync" ["id", U.member "id" request;
                "status", `Int response.status; "body", `String response.body; "error", `Null] in
              pump completed in
          pump (dispatch "beginPendingSync" []);
          pull ()
        done;
        let downloaded = Live.download_asset cfg uuid "png" in
        let actual = if encrypted then Live.require_ok "decrypt uploaded asset" (E2ee.decrypt_bytes crypto key downloaded.body) else downloaded.body in
        if actual <> bytes then failwith "Uploaded image bytes differ";
        let blocks = Option.get (Mobile_graph.authoritative_blocks host.database.graph) in
        if not (List.exists (fun (b : Cache_model.block) -> b.uuid = uuid && b.is_asset) blocks) then
          failwith "Asset never reached authoritative graph";
        print_endline "PASS: real mobile capture, pending upload, datom sync and journal replay")))
