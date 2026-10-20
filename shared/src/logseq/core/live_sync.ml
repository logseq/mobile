module Json = Yojson.Basic
module Ds = Datascript

let contents_page_uuid = "00000004-1690-2597-3200-000000000000"

let fail step message = failwith (step ^ ": " ^ message)

let require_ok step result =
  match result with
  | Ok value -> value
  | Error message -> fail step message

let env name =
  match Sys.getenv_opt name with
  | Some value ->
    let value = String.trim value in
    if value = "" then
      failwith ("missing required environment variable " ^ name)
    else value
  | None -> failwith ("missing required environment variable " ^ name)

let json_object body =
  try
    match Json.from_string body with
    | `Assoc _ as input -> input
    | _ -> failwith ("expected a JSON object: " ^ body)
  with Yojson.Json_error message -> failwith ("invalid JSON: " ^ message)

let json_string name input =
  match Api.member name input with
  | `String value -> Some value
  | _ -> None

let json_int name input =
  match Api.member name input with
  | `Int value -> Some value
  | `Float value -> Some (int_of_float value)
  | _ -> None

let expect_response step accepted result =
  let response = require_ok step result in
  if List.exists (fun status -> status = response.Api.status) accepted then
    response
  else
    fail step
      (Printf.sprintf "HTTP %d %s" response.Api.status
         response.Api.body)

let expect step accepted request =
  expect_response step accepted (Http.send request)

let config base_url token graph_id =
  {
    Api.base_url;
    token;
    graph_id;
    graph_name = None;
  }

let write_temp prefix contents =
  let path = Filename.temp_file prefix ".bin" in
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents);
  path

let remove_file path = try Sys.remove path with _ -> ()

let rec remove_tree path =
  try
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Array.iter
          (fun name -> remove_tree (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
      end
      else Sys.remove path
  with _ -> ()

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)

let absolute_url base_url url =
  if
    String.starts_with ~prefix:"http://" url
    || String.starts_with ~prefix:"https://" url
  then url
  else if String.starts_with ~prefix:"/" url then
    Api.api_root (config base_url "" "") ^ url
  else url

let merge_pull_cursor metadata body =
  try
    let input = Json.from_string body in
    if json_string "type" input = Some "pull/ok" then
      match json_int "t" input with
      | Some t ->
        { metadata with Sync_session.baseline_t = t }
      | None -> metadata
    else metadata
  with _ -> metadata

let download_snapshot cfg =
  let path = "/sync/" ^ Api.url_encode cfg.Api.graph_id in
  let pull = expect "snapshot watermark" [ 200 ]
      (Api.request cfg "GET" (path ^ "/pull?since=9007199254740991") None) in
  let response = expect "snapshot metadata" [ 200 ]
      (Api.request cfg "GET" (path ^ "/snapshot/download") None) in
  let cursor =
    match json_int "t" (json_object pull.Api.body) with
    | Some t when t >= 0 -> t
    | _ -> fail "snapshot watermark" "missing non-negative cursor"
  in
  let fields = match Json.from_string response.Api.body with
    | `Assoc fields -> fields
    | _ -> fail "snapshot metadata" "expected object"
  in
  let metadata = require_ok "decode snapshot metadata"
      (Sync_session.decode_snapshot_metadata
         (Json.to_string (`Assoc (("t", `Int cursor) :: List.remove_assoc "t" fields)))) in
  let metadata = merge_pull_cursor metadata pull.Api.body in
  let request =
    {
      Api.method_ = "GET";
      url = absolute_url cfg.base_url metadata.Sync_session.url;
      body = None;
      token = cfg.token;
    }
  in
  let stream = expect "snapshot stream" [ 200 ] request in
  if stream.Api.body = "" then fail "snapshot stream" "empty snapshot body";
  (metadata, write_temp "logseq-live-snapshot" stream.Api.body)

let import_downloaded graph_id decrypt dir metadata download_path =
  let active_path = Filename.concat dir "graph.sqlite" in
  let checkpoint = Filename.concat dir "sync.checkpoint" in
  ignore
    (require_ok "import snapshot"
       (Sync_session.import_snapshot_file decrypt graph_id active_path
          checkpoint metadata download_path));
  active_path

let has_title db decrypt expected =
  Ds.Db.datoms db Ds.Aevt ~a:"block/title" ()
  |> Seq.exists (fun (datom : Ds.datom) ->
         match datom.v with
         | Ds.String value ->
           (expected
            = match decrypt value with
              | Ok title -> title
              | Error _ -> value)
         | _ -> false)

let apply_journal decrypt current body =
  let journal = require_ok "decode journal" (Journal_sync.decode body) in
  let ids, changed = require_ok "apply canonical journal"
      (Journal_sync.apply decrypt current.Graph_runtime.conn
         (Graph_runtime.state current).server_t journal) in
  Graph_runtime.rebase current journal.t ids changed

let rec submit_tx ?(decrypt = fun value -> Ok value) cfg current operation attempts =
  if attempts <= 0 then
    fail "tx/batch" "exhausted retries after stale cursor"
  else begin
    let outliner_op, tx =
      require_ok "prepare outliner op"
        (Graph_runtime.prepare_sync current operation)
    in
    let request =
      Api.tx_batch_request cfg
        (Graph_runtime.state current).server_t
        operation.Pending_ops.operation_id outliner_op tx
    in
    let response = expect "tx/batch" [ 200; 409 ] request in
    let fields = json_object response.Api.body in
    match
      ( json_string "type" fields
      , json_int "t" fields
      , json_string "reason" fields )
    with
    | Some "tx/batch/ok", Some t, _ ->
      apply_journal decrypt current response.Api.body
    | Some "tx/reject", Some t, Some "stale" ->
      let pull = expect "pull stale journal" [ 200 ]
          (Api.request cfg "GET" ("/sync/" ^ Api.url_encode cfg.Api.graph_id
             ^ "/pull?since=" ^ string_of_int (Graph_runtime.state current).server_t) None) in
      apply_journal decrypt current pull.Api.body;
      submit_tx ~decrypt cfg current operation (attempts - 1)
    | _ ->
      fail "tx/batch"
        (Printf.sprintf "unexpected response HTTP %d %s"
           response.Api.status response.Api.body)
  end

let stage_insert current page_uuid title =
  let intent =
    Pending_ops.Insert_block
      {
        Pending_ops.uuid = Graph_runtime.fresh_uuid ();
        title;
        page_uuid;
        parent_uuid = page_uuid;
        order = require_ok "fractional order" (Fractional_order.between None None);
        created_at = Api.epoch_ms ();
      }
  in
  let operation =
    Graph_runtime.queued_operation current (Graph_runtime.fresh_uuid ())
      intent
  in
  require_ok "stage insert" (Graph_runtime.stage current operation);
  operation

let stage_asset current page_uuid title asset_type asset_size asset_checksum =
  let uuid = Graph_runtime.fresh_uuid () in
  let intent =
    Pending_ops.Create_asset
      {
        Pending_ops.uuid;
        title;
        page_uuid;
        parent_uuid = page_uuid;
        order =
          require_ok "asset order" (Fractional_order.between (Some "a0") None);
        created_at = Api.epoch_ms ();
        asset_type;
        asset_size;
        asset_checksum;
        transcript = None;
      }
  in
  let operation =
    Graph_runtime.queued_operation current (Graph_runtime.fresh_uuid ())
      intent
  in
  require_ok "stage asset" (Graph_runtime.stage current operation);
  (uuid, operation)

let ensure_user_keys cfg =
  ignore
    (expect "e2ee user keys" [ 200; 201 ]
       (Api.request cfg "POST" "/e2ee/user-keys"
          (Api.json_body
             [
               ("public-key", `String "live-sync-public-key");
               ( "encrypted-private-key"
               , `String "live-sync-encrypted-private-key" );
             ])))

let upload step request =
  let response = require_ok step (Http.upload_file request) in
  if not (200 <= response.Api.status && response.Api.status <= 299) then
    fail step
      (Printf.sprintf "HTTP %d %s" response.Api.status
         response.Api.body)

let create_and_upload cfg name e2ee encrypt_text =
  let response =
    expect "create graph" [ 200; 201 ]
      (Api.create_graph_request cfg name Graph_bootstrap.schema_version e2ee)
  in
  let graph_id =
    match json_string "graph-id" (json_object response.Api.body) with
    | Some graph_id -> graph_id
    | None ->
      fail "create graph" ("missing graph-id in " ^ response.Api.body)
  in
  let cfg = { cfg with Api.graph_id } in
  if e2ee then
    ignore
      (expect "e2ee graph aes key" [ 200; 201 ]
         (Api.upsert_graph_key_request cfg "live-sync-encrypted-aes-key"));
  (let prepared =
     require_ok "prepare initial snapshot"
       (Graph_bootstrap.prepare graph_id e2ee encrypt_text)
   in
   Fun.protect
     ~finally:(fun () -> remove_file prepared.Graph_bootstrap.file_path)
     (fun () ->
       upload "initial snapshot upload"
         (Api.initial_snapshot_upload_request cfg prepared.file_path
            prepared.checksum)));
  let listed = expect "list graphs" [ 200 ] (Api.graphs_request cfg) in
  let graph =
    List.find_opt
      (fun (graph : Api.api_graph) -> graph.id = graph_id)
      (Api.graphs_from_graphs_body listed.Api.body)
  in
  (match graph with
   | Some graph ->
     if graph.e2ee <> e2ee then
       fail "list graphs" "created graph encryption flag mismatch";
     if not graph.ready then
       fail "list graphs"
         "created graph is not ready after snapshot upload"
   | None ->
     fail "list graphs"
       ("created graph is missing from GET /graphs: " ^ listed.Api.body));
  cfg

let upload_asset_file cfg uuid asset_type checksum bytes content_type =
  let path = write_temp "logseq-live-asset" bytes in
  Fun.protect
    ~finally:(fun () -> remove_file path)
    (fun () ->
      upload "asset upload"
        (Api.raw_asset_upload_request cfg uuid asset_type checksum path
           content_type))

let download_asset cfg uuid asset_type =
  expect "asset download" [ 200 ]
    (Api.request cfg "GET"
       ("/assets/" ^ Api.url_encode cfg.Api.graph_id ^ "/"
        ^ Api.url_encode uuid ^ "." ^ Api.url_encode asset_type)
       None)

let asset_mismatch expected actual =
  "expected " ^ Printf.sprintf "%S" expected ^ ", got "
  ^ Printf.sprintf "%S" actual

let verify_titles cfg decrypt label block_title asset_title capture_title =
  let metadata, path = download_snapshot cfg in
  Fun.protect
    ~finally:(fun () -> remove_file path)
    (fun () ->
      with_temp_dir "logseq-live-verify" (fun dir ->
          let verify_path =
            import_downloaded cfg.Api.graph_id decrypt dir metadata path
          in
          let db =
            require_ok "restore verified graph"
              (Graph_store.restore_db verify_path)
          in
          let decode =
            match decrypt with
            | Some decrypt -> decrypt
            | None -> fun value -> Ok value
          in
          List.iter
            (fun (step, kind, title) ->
              if not (has_title db decode title) then
                fail step
                  ("missing " ^ kind
                   ^ " title after re-download: " ^ title))
            [
              ("verify outliner sync", "block", block_title);
              ("verify asset block", "asset", asset_title);
              ("verify capture sync", "capture", capture_title);
            ];
          print_endline
            ("ok " ^ label ^ " graph_id=" ^ cfg.Api.graph_id ^ " t="
             ^ string_of_int metadata.Sync_session.baseline_t)))

let run_mode base_url token e2ee =
  let label = if e2ee then "encrypted" else "unencrypted" in
  let encrypt_text value = Ok (if e2ee then "enc:" ^ value else value) in
  let decrypt value =
    Ok
      (if e2ee && String.starts_with ~prefix:"enc:" value then
         String.sub value 4 (String.length value - 4)
       else value)
  in
  let cfg = config base_url token "" in
  print_endline
    ("==> " ^ label ^ " graph create / download / outliner / asset");
  if e2ee then ensure_user_keys cfg;
  let name =
    Printf.sprintf "live-%s-%d" (if e2ee then "enc" else "plain")
      (Api.epoch_ms ())
  in
  let cfg = create_and_upload cfg name e2ee encrypt_text in
  let metadata, path = download_snapshot cfg in
  Fun.protect
    ~finally:(fun () -> remove_file path)
    (fun () ->
      with_temp_dir "logseq-live-import" (fun dir ->
          let decrypt_protected = if e2ee then Some decrypt else None in
          let active_path =
            import_downloaded cfg.Api.graph_id decrypt_protected dir
              metadata path
          in
          let conn =
            require_ok "restore graph" (Graph_store.restore_conn active_path)
          in
          let current =
            Graph_runtime.create active_path
              metadata.Sync_session.baseline_t conn
              {
                Graph_runtime.default_options with
                encrypt_title = encrypt_text;
              }
          in
          let block_title = "live-outliner-" ^ label in
          let asset_bytes = "live-asset-" ^ label in
          let asset_type = "png" in
          let checksum = Digest.to_hex (Digest.string asset_bytes) in
          let asset_title = "live-asset-" ^ label ^ ".png" in
          let capture_title = "live-capture-" ^ label in
          if
            Ds.entid (Ds.conn_db conn) "block/uuid"
              (Ds.Uuid contents_page_uuid)
            = None
          then
            fail "import snapshot"
              "Contents page is missing after snapshot import";
          submit_tx ~decrypt cfg current
            (stage_insert current contents_page_uuid block_title)
            4;
          (let uuid, operation =
             stage_asset current contents_page_uuid asset_title asset_type
               (String.length asset_bytes) checksum
           in
           upload_asset_file cfg uuid asset_type checksum asset_bytes
             (if e2ee then "text/plain"
              else Api.content_type_for_asset_type asset_type);
           submit_tx ~decrypt cfg current operation 4;
           let downloaded = download_asset cfg uuid asset_type in
           if downloaded.Api.body <> asset_bytes then
             fail "asset download"
               (asset_mismatch asset_bytes downloaded.Api.body));
          submit_tx ~decrypt cfg current
            (stage_insert current contents_page_uuid capture_title) 4;
          verify_titles cfg decrypt_protected label block_title
            asset_title capture_title))

let run () =
  let token = env "LOGSEQ_LIVE_TOKEN" in
  let base_url =
    match Sys.getenv_opt "LOGSEQ_LIVE_BASE_URL" with
    | Some url -> url
    | None -> "http://127.0.0.1:8787"
  in
  run_mode base_url token false;
  run_mode base_url token true;
  print_endline "live sync flows passed"
