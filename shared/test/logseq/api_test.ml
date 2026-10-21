open Test_util

module Json = Yojson.Basic
module Util = Yojson.Basic.Util

let config : Api.api_config =
  {
    Api.base_url = "https://api.example";
    graph_id = "graph-1";
    graph_name = None;
    token = "token";
  }

let url_encoding_and_secure_metadata_defaults () =
  check_eq "a%20b%2F%3F%23%25%2B%C3%A9-_.~"
    (Api.url_encode "a b/?#%+é-_.~");
  let graphs =
    Api.graphs_from_graphs_body
      "{\"graphs\":[null,{}, {\"graph-id\":\"\"},{\"graph-id\":\"safe\",\"graph-name\":\"\",\"schema-version\":\"\",\"graph-e2ee?\":\"false\",\"graph-ready-for-use?\":1}]}"
  in
  check_eq 1 (List.length graphs);
  let (graph : Api.api_graph) = List.hd graphs in
  check_eq "safe" graph.id;
  check_eq "safe" graph.name;
  check_eq None graph.schema_version;
  check graph.e2ee;
  check (not graph.ready);
  List.iter
    (fun body ->
      check
        (try
           ignore (Api.created_block_uuid_from_body body);
           false
         with
         | Failure _ -> true))
    [
      "[]";
      "{\"uuid\":\" \",\"blocks\":[]}";
      "{\"blocks\":[{\"uuid\":\"\"}]}";
    ]

let read_endpoints () =
  List.iter
    (fun ((request : Api.api_request), suffix) ->
      check_eq "GET" request.method_;
      check_eq ("https://api.example" ^ suffix) request.url)
    [
      (Api.graphs_request config, "/graphs");
      (Api.user_keys_request config, "/e2ee/user-keys");
      (Api.graph_key_request config, "/e2ee/graphs/graph-1/aes-key");
    ]

let capture_and_task_bodies () =
  List.iter
    (fun ((request : Api.api_request), body) ->
      check_eq (Some body) request.body)
    [
      ( Api.capture_request None config "client-block" "Offline"
      , "{\"blocks\":[{\"uuid\":\"client-block\",\"title\":\"Offline\"}]}" );
      ( Api.capture_request (Some "journal-1") config "encrypted-block"
          "encrypted-title"
      , "{\"page-id\":\"journal-1\",\"blocks\":[{\"uuid\":\"encrypted-block\",\"title\":\"encrypted-title\"}]}"
      );
      ( Api.task_request None config "client-task" "waiting" "Follow up"
      , "{\"uuid\":\"client-task\",\"title\":\"Follow up\",\"status\":\"waiting\"}"
      );
      ( Api.task_request (Some "journal-1") config "encrypted-task" "waiting"
          "encrypted-title"
      , "{\"uuid\":\"encrypted-task\",\"title\":\"encrypted-title\",\"status\":\"waiting\",\"page-id\":\"journal-1\"}"
      );
    ];
  check_eq "POST"
    (Api.task_request None config "client-task" "waiting" "Follow up")
      .method_

let status_and_transaction_requests () =
  let status =
    Api.update_block_status_request config "task-1" "custom-waiting"
  in
  let tx =
    Api.tx_batch_request config 42 "018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8"
      "split-block" "[\"~:db/add\"]"
  in
  check_eq "PUT" status.Api.method_;
  check_eq
    "https://api.example/api/v1/graphs/graph-1/blocks/task-1/properties/Status"
    status.url;
  check_eq (Some "{\"value\":\"custom-waiting\"}") status.body;
  check_eq "POST" tx.Api.method_;
  check_eq "https://api.example/sync/graph-1/tx/batch" tx.url;
  check_eq
    (Some
       "{\"t-before\":42,\"txs\":[{\"tx-id\":\"018f7850-c6aa-7da0-8b3f-6dbb64aa4ec8\",\"tx\":\"[\\\"~:db/add\\\"]\",\"outliner-op\":\"split-block\"}]}")
    tx.body

let asset_upload_metadata () =
  let upload =
    Api.raw_asset_upload_request config "client-asset" "jpg" "abc123"
      "/documents/photo.jpg" "image/jpeg"
  in
  let encrypted =
    Api.raw_asset_upload_request config "encrypted-asset" "jpg" "abc123"
      "/documents/encrypted-photo.transit" "text/plain"
  in
  check_eq "/documents/photo.jpg" upload.Api.file_path;
  check_eq "image/jpeg" upload.content_type;
  check_eq "jpeg" (Api.normalize_asset_type "image/jpeg");
  check_eq "IMG_0002.jpeg" (Api.asset_file_name "IMG_0002" "image/jpeg");
  check_eq "image/jpeg" (Api.content_type_for_asset_type "image/jpeg");
  check_eq "PUT" upload.request.method_;
  check_eq "https://api.example/assets/graph-1/client-asset.jpg"
    upload.request.url;
  check_eq None upload.request.body;
  check
    (List.mem ("x-amz-meta-checksum", "abc123") upload.Api.headers);
  check (List.mem ("x-amz-meta-type", "jpg") upload.headers);
  check_eq "https://api.example/assets/graph-1/encrypted-asset.jpg"
    encrypted.request.url;
  check_eq "text/plain" encrypted.Api.content_type

let asset_upload_query_parameters () =
  let plain =
    Api.asset_upload_request None config "asset/1" "photo 1.jpg" 0 "a+b"
      "/tmp/photo.jpg" "image/jpeg"
  in
  let paged =
    Api.asset_upload_request (Some "page/1") config "asset" "photo.jpg" 2048
      "hash" "/tmp/photo.jpg" "image/jpeg"
  in
  let encrypted =
    Api.encrypted_asset_upload_request config "asset" "photo.jpg"
      "cipher+text" "page/1" 2048 4096 "hash" "/tmp/encrypted"
  in
  check_eq
    "https://api.example/api/v1/graphs/graph-1/assets?uuid=asset%2F1&file-name=photo%201.jpg&size=0&checksum=a%2Bb"
    plain.Api.request.url;
  check_eq
    "https://api.example/api/v1/graphs/graph-1/assets?uuid=asset&file-name=photo.jpg&size=2048&checksum=hash&page-id=page%2F1"
    paged.request.url;
  check_eq
    "https://api.example/api/v1/graphs/graph-1/assets?uuid=asset&file-name=photo.jpg&size=2048&upload-size=4096&checksum=hash&title=cipher%2Btext&page-id=page%2F1"
    encrypted.request.url;
  check_eq "POST" encrypted.request.method_;
  check_eq "text/plain" encrypted.Api.content_type;
  check_eq "/tmp/encrypted" encrypted.file_path;
  check_eq None encrypted.request.body

let creation_responses () =
  List.iter
    (fun (body, expected) ->
      check_eq expected (Api.created_block_uuid_from_body body))
    [
      ( "{\"uuid\":\"server-asset\",\"title\":\"photo.jpg\",\"type\":\"jpg\",\"size\":2048,\"checksum\":\"abc123\"}"
      , "server-asset" );
      ( "{\"uuid\":\"server-task\",\"title\":\"Follow up\",\"status\":{\"title\":\"Todo\"}}"
      , "server-task" );
      ( "{\"page-id\":\"journal\",\"blocks\":[{\"uuid\":\"server-block\",\"title\":\"Offline\"}]}"
      , "server-block" );
    ]

let key_packages () =
  let upsert = Api.upsert_graph_key_request config "wrapped" in
  let body =
    Json.from_string (match upsert.Api.body with Some b -> b | None -> "")
  in
  check_eq "POST" upsert.method_;
  check_eq "wrapped" (Util.to_string (Util.member "encrypted-aes-key" body));
  check_eq "private-package"
    (Api.user_keys_from_body
       "{\"public-key\":\"public\",\"encrypted-private-key\":\"private-package\"}")
      .Api.encrypted_private_key;
  check_eq "graph-package"
    (Api.graph_key_from_body "{\"encrypted-aes-key\":\"graph-package\"}")

let graph_creation_and_discovery () =
  let configuration : Api.api_config =
    {
      Api.base_url = "https://api.example.com/api";
      graph_id = "";
      graph_name = None;
      token = "token";
    }
  in
  let request =
    Api.create_graph_request configuration "Private notes" "65.33" true
  in
  let body =
    Json.from_string (match request.Api.body with Some b -> b | None -> "")
  in
  check_eq "POST" request.method_;
  check_eq "https://api.example.com/graphs" request.url;
  check_eq "Private notes" (Util.to_string (Util.member "graph-name" body));
  check_eq "65.33" (Util.to_string (Util.member "schema-version" body));
  check (Util.to_bool (Util.member "graph-e2ee?" body));
  check (not (Util.to_bool (Util.member "graph-ready-for-use?" body)));
  let graphs =
    Api.graphs_from_graphs_body
      "{\"graphs\":[{\"graph-id\":\"plain-1\",\"graph-name\":\"Plain\",\"schema-version\":\"65.33\",\"graph-e2ee?\":false,\"graph-ready-for-use?\":true},{\"graph-id\":\"encrypted-1\",\"graph-name\":\"Encrypted\",\"graph-e2ee?\":true,\"graph-ready-for-use?\":false}]}"
  in
  check_eq 2 (List.length graphs);
  let plain = List.nth graphs 0 in
  let encrypted = List.nth graphs 1 in
  check_eq (Some "65.33") plain.Api.schema_version;
  check_eq "plain-1" plain.id;
  check_eq "Plain" plain.name;
  check (not plain.e2ee);
  check plain.ready;
  check_eq "encrypted-1" encrypted.Api.id;
  check encrypted.e2ee;
  check (not encrypted.ready)

let initial_snapshot_upload () =
  let configuration : Api.api_config =
    {
      Api.base_url = "https://api.example.com/api";
      graph_id = "graph id";
      graph_name = Some "Fresh graph";
      token = "token";
    }
  in
  let upload =
    Api.initial_snapshot_upload_request configuration
      "/tmp/initial.snapshot" "0000000000000000"
  in
  check_eq "POST" upload.Api.request.method_;
  check_eq
    "https://api.example.com/sync/graph%20id/snapshot/upload?reset=true&finished=true&checksum=0000000000000000"
    upload.request.url;
  check_eq "application/transit+json" upload.content_type;
  check_eq "/tmp/initial.snapshot" upload.file_path

let shared_graph_membership_survives_the_rpc_boundary () =
  List.iter
    (fun (role, expected) ->
       let body = Yojson.Basic.to_string (`Assoc [ "graphs", `List [
         `Assoc ([ "graph-id", `String "shared"; "graph-name", `String "personal";
                   "graph-e2ee?", `Bool true; "graph-ready-for-use?", `Bool true ]
                 @ (match role with None -> [] | Some role -> [ "role", `String role ])) ] ]) in
       let graph = List.hd (Api.graphs_from_graphs_body body) in
       let wire = Rpc_encode.graph_json graph in
       check_eq expected (Util.member "role" wire);
       check_eq (`Bool true) (Util.member "isEncrypted" wire);
       check_eq (`Bool true) (Util.member "isReady" wire))
    [ Some "member", `String "member"; Some "manager", `String "manager";
      None, `Null; Some "", `Null ]

let cases =
  [
    case "url encoding and secure metadata defaults"
      url_encoding_and_secure_metadata_defaults;
    case "shared graph membership survives the RPC boundary" shared_graph_membership_survives_the_rpc_boundary;
    case "read endpoints" read_endpoints;
    case "capture and task bodies" capture_and_task_bodies;
    case "status and transaction requests" status_and_transaction_requests;
    case "asset upload metadata" asset_upload_metadata;
    case "asset upload query parameters" asset_upload_query_parameters;
    case "creation responses" creation_responses;
    case "key packages" key_packages;
    case "graph creation and discovery" graph_creation_and_discovery;
    case "initial snapshot upload" initial_snapshot_upload;
  ]
